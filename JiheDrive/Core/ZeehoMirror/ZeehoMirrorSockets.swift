import Foundation
import Network

/// NWConnection 的薄封装：带缓冲的定长读取（首字节可长等、续读限时）
/// 与异步写入。投屏会话的每条 TCP 通道各持一个实例。
final class ZeehoMirrorChannel {

    enum ChannelError: LocalizedError, CustomStringConvertible {
        case closed(String)
        case timeout(String)
        case network(String, String)

        var errorDescription: String? {
            switch self {
            case .closed(let what): return "\(what)已关闭"
            case .timeout(let what): return "\(what)等待超时"
            case .network(let what, let detail): return "\(what)：\(detail)"
            }
        }

        var description: String { errorDescription ?? "通道错误" }
    }

    private struct PendingRead {
        let need: Int
        var firstByteSeen: Bool
        let continuation: CheckedContinuation<Data, Error>
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    private var pendingRead: PendingRead?
    private var timeoutWorkItem: DispatchWorkItem?
    private var receiveActive = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func startPump() {
        queue.async { [weak self] in self?.pump() }
    }

    /// 连接目标地址并等待就绪。
    static func connect(host: String, port: UInt16, name: String,
                        timeout: TimeInterval = 5) async throws -> ZeehoMirrorChannel {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ChannelError.network("\(name)连接", "端口非法 \(port)")
        }
        let queue = DispatchQueue(label: "zeeho.mirror.\(name)")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var timeoutItem: DispatchWorkItem!
            let finish: (Result<ZeehoMirrorChannel, Error>) -> Void = { result in
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                guard !already else { return }
                timeoutItem.cancel()
                continuation.resume(with: result)
            }
            timeoutItem = DispatchWorkItem {
                connection.cancel()
                finish(.failure(ChannelError.timeout("\(name)连接")))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let channel = ZeehoMirrorChannel(connection: connection, queue: queue)
                    finish(.success(channel))
                    channel.startPump()
                case .failed(let error):
                    finish(.failure(ChannelError.network("\(name)连接", error.localizedDescription)))
                case .cancelled:
                    finish(.failure(ChannelError.closed("\(name)连接")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    let wrapped = ChannelError.network("写入", error.localizedDescription)
                    self?.fail(wrapped)
                    continuation.resume(throwing: wrapped)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// 定长读取。`waitForFirstByte` 为 true 时首字节不限时（通道可长时间静默），
    /// 一旦开始接收就在 `timeout` 内读完剩余部分。
    func readExactly(_ count: Int, timeout: TimeInterval = 5, waitForFirstByte: Bool = false) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                guard !self.closed else {
                    continuation.resume(throwing: ChannelError.closed("通道"))
                    return
                }
                if self.buffer.count >= count {
                    let data = Data(self.buffer.prefix(count))
                    self.buffer.removeFirst(count)
                    continuation.resume(returning: data)
                    return
                }
                self.pendingRead = PendingRead(need: count, firstByteSeen: !waitForFirstByte, continuation: continuation)
                self.armTimeout(count: count, gracePeriod: waitForFirstByte)
            }
        }
    }

    private func armTimeout(count: Int, gracePeriod: Bool) {
        timeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingRead, pending.need == count else { return }
            self.pendingRead = nil
            pending.continuation.resume(throwing: ChannelError.timeout("仪表数据"))
        }
        timeoutWorkItem = item
        let interval: TimeInterval = gracePeriod ? max(120, 0) : 5
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// 收到数据就往缓冲里灌，凑够 pendingRead 的量就唤醒等待方。
    private func pump() {
        guard !closed, !receiveActive else { return }
        receiveActive = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.receiveActive = false
                guard !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    if let pending = self.pendingRead, !pending.firstByteSeen {
                        self.pendingRead?.firstByteSeen = true
                        self.armTimeout(count: pending.need, gracePeriod: false)
                    }
                    self.deliverIfPossible()
                }
                if let error {
                    self.fail(ChannelError.network("接收", error.localizedDescription))
                    return
                }
                if isComplete {
                    self.fail(ChannelError.closed("连接"))
                    return
                }
                self.pump()
            }
        }
    }

    private func deliverIfPossible() {
        guard let pending = pendingRead, buffer.count >= pending.need else { return }
        pendingRead = nil
        timeoutWorkItem?.cancel()
        let data = Data(buffer.prefix(pending.need))
        buffer.removeFirst(pending.need)
        pending.continuation.resume(returning: data)
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        timeoutWorkItem?.cancel()
        if let pending = pendingRead {
            pendingRead = nil
            pending.continuation.resume(throwing: error)
        }
        connection.cancel()
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.timeoutWorkItem?.cancel()
            if let pending = self.pendingRead {
                self.pendingRead = nil
                pending.continuation.resume(throwing: ChannelError.closed("通道"))
            }
            self.connection.cancel()
        }
    }
}

/// 监听仪表回连的 TCP 服务端。
final class ZeehoMirrorListener {

    struct ListenerError: LocalizedError {
        let port: UInt16
        var errorDescription: String? { "端口 \(port) 监听失败" }
    }

    private var listener: NWListener?
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 新连接在监听队列上回调（连接已 start 并开始收包）。
    func start(port: UInt16, onConnection: @escaping (ZeehoMirrorChannel) -> Void) throws {
        guard let portValue = NWEndpoint.Port(rawValue: port) else { throw ListenerError(port: port) }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: portValue)
        } catch {
            throw ListenerError(port: port)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let channel = ZeehoMirrorChannel(connection: connection, queue: self.queue)
            connection.stateUpdateHandler = { [weak self] state in
                if state == .ready {
                    channel.startPump()
                    self?.queue.async { onConnection(channel) }
                } else if case .failed = state {
                    channel.close()
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
