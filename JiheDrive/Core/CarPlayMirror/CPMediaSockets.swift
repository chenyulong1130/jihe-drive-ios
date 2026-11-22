import Foundation
import Darwin

/// 媒体通道 socket 助手：SETUP 回包前必须同步绑好端口并拿到端口号，
/// 因此用 POSIX 而不是 NWListener（后者的端口要等 ready 回调）。

/// 接受 iPhone 回连的 TCP 服务端（事件通道 / 视频通道各一个）。
final class CPMediaTCPListener {
    let port: UInt16
    private var source: DispatchSourceRead?
    private var fd: Int32
    var onConnection: ((CPMediaTCPConnection) -> Void)?

    init(queue: DispatchQueue, peerAddress: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CPError.malformed("媒体 socket 创建失败") }
        self.fd = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        var allowed = in_addr()
        guard inet_pton(AF_INET, peerAddress, &allowed) == 1 else {
            close(fd)
            throw CPError.malformed("媒体对端地址需要 IPv4")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            throw CPError.malformed("媒体端口绑定失败")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }
        guard named == 0 else {
            close(fd)
            throw CPError.malformed("读取媒体端口失败")
        }
        port = UInt16(bigEndian: address.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var remote = sockaddr_in()
            var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &count)
                }
            }
            guard client >= 0 else { return }
            guard remote.sin_addr.s_addr == allowed.s_addr, let callback = self.onConnection else {
                close(client)
                return
            }
            callback(CPMediaTCPConnection(fd: client, queue: queue))
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        onConnection = nil
    }

    deinit { stop() }
}

/// 单条已建立的媒体连接（读回调 + 发送队列）。
final class CPMediaTCPConnection {
    private let io: DispatchIO
    private let queue: DispatchQueue
    private var pending = 0
    private var stopped = false
    var onBytes: ((Data) throws -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.queue = queue
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        io.setLimit(lowWater: 1)
        io.setLimit(highWater: 65536)
    }

    func start() {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self, !self.stopped else { return }
            do {
                if let data, !data.isEmpty {
                    try self.onBytes?(Data(data))
                }
            } catch {
                self.stop()
                self.onClose?()
                return
            }
            if done || error != 0 {
                self.stop()
                self.onClose?()
            }
        }
    }

    func send(_ data: Data) throws {
        guard !stopped, pending + data.count <= 256 * 1024 else {
            throw CPError.limitExceeded("事件输出队列")
        }
        pending += data.count
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: bytes, queue: queue) { [weak self] done, _, error in
            guard let self else { return }
            if done { self.pending -= data.count }
            if error != 0 {
                self.stop()
                self.onClose?()
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        io.close(flags: .stop)
        onBytes = nil
    }

    deinit { stop() }
}

/// CarPlay 时钟同步（NTP 风格 UDP，端口来自初始 SETUP 的 timingPort）。
final class CPMediaTiming {
    let port: UInt16
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var fd: Int32 = -1
    private var pending: Data?
    private var offset: Double = 0
    private let origin = Date().timeIntervalSince1970 + 2_208_988_800 // NTP 纪元
    private let monotonic = ProcessInfo.processInfo.systemUptime

    private func now() -> Double {
        origin + ProcessInfo.processInfo.systemUptime - monotonic + offset
    }

    func timestamp() -> UInt64 {
        Self.encode(now()).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func encode(_ time: Double) -> Data {
        let seconds = UInt64(time.rounded(.down))
        let fraction = UInt64((time - time.rounded(.down)) * 4_294_967_296)
        let value = (seconds << 32) | fraction
        return Data(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    private static func decode(_ bytes: Data) -> Double {
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(value >> 32) + Double(value & 0xffff_ffff) / 4_294_967_296
    }

    init(queue: DispatchQueue, peerAddress: String, peerPort: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw CPError.malformed("时钟同步 socket 创建失败") }
        self.fd = fd
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = peerPort.bigEndian
        guard inet_pton(AF_INET, peerAddress, &remote.sin_addr) == 1 else {
            close(fd)
            throw CPError.malformed("时钟同步对端地址")
        }
        var local = sockaddr_in()
        local.sin_len = remote.sin_len
        local.sin_family = remote.sin_family
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            throw CPError.malformed("时钟同步绑定失败")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }
        guard named == 0 else {
            close(fd)
            throw CPError.malformed("读取时钟端口失败")
        }
        port = UInt16(bigEndian: local.sin_port)
        let send: (Data) -> Void = { [weak self] payload in
            guard let self, self.fd >= 0 else { return }
            payload.withUnsafeBytes { bytes in
                _ = withUnsafePointer(to: &self.remoteAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(self.fd, bytes.baseAddress, bytes.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        self.sendFn = send
        self.remoteAddr = remote
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 2048)
            var peer = sockaddr_in()
            var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let length = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &bytes, bytes.count, 0, $0, &count)
                }
            }
            guard length == 32, peer.sin_addr.s_addr == remote.sin_addr.s_addr,
                  peer.sin_port == remote.sin_port else { return }
            let message = Data(bytes.prefix(length))
            if bytes[1] == 210 {
                // iPhone 的时钟请求：立即回 NTP 响应
                var response = Data([0x80, 211, 0, 7]) + Data(count: 4)
                response += message.suffix(8)
                response += Self.encode(self.now())
                response += Self.encode(self.now())
                send(response)
            } else if bytes[1] == 211, let pending = self.pending,
                      message.subdata(in: 8..<16) == pending {
                // 我们发出的请求的响应：估算 RTT 并校正时钟偏移
                let t1 = Self.decode(pending)
                let t2 = Self.decode(message.subdata(in: 16..<24))
                let t3 = Self.decode(message.suffix(8))
                let t4 = self.now()
                let rtt = (t4 - t1) - (t3 - t2)
                if rtt >= 0, rtt < 1 {
                    self.offset += ((t2 - t1) + (t3 - t4)) / 2
                }
                self.pending = nil
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        if peerPort != 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let stamp = Self.encode(self.now())
                self.pending = stamp
                send(Data([0x80, 210, 0, 7]) + Data(count: 20) + stamp)
            }
            timer.resume()
        }
    }

    private var sendFn: ((Data) -> Void)?
    private var remoteAddr: sockaddr_in

    func stop() {
        timer?.cancel()
        timer = nil
        source?.cancel()
        source = nil
        fd = -1
    }

    deinit { stop() }
}
