import Foundation
import Network

/// 浏览器查看服务：把 CarPlay 画面以 MJPEG 形式提供给任意浏览器——
/// 本机内嵌窗口、同一网络的 iPad / 电脑都能打开；触控与按键经 HTTP 回传 HID。
/// 页面与流都走最简单的 HTTP（GET / 页面、GET /video.mjpg、POST /touch、POST /key）。
final class CPBrowserServer {

    struct Viewer {
        let id: UUID
        let connection: NWConnection
        var writing = false
        var pending: Data?
    }

    static let boundary = "jihedriveframe"

    /// 触控回传（归一化 0…1 坐标）。
    var onTouch: ((_ id: Int, _ x: Double, _ y: Double, _ down: Bool) -> Void)?
    /// 按键回传："home" / "back" / "select" / "siri"。
    var onKey: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// 第一个观看者连上（true）/ 最后一个断开（false）——上层据此启停出帧。
    var onViewerCountChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "cp.browser.server")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var viewers: [UUID: Viewer] = [:]
    private var _port: UInt16 = 0
    private var generation = UUID()

    /// 服务端口（start 成功后有效；首选端口被占用时系统分配）。
    var port: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _port
    }

    func start(preferredPort: UInt16 = 8089) {
        stop()
        let token = UUID()
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = token
            self.listen(on: preferredPort, token: token)
        }
    }

    func stop() {
        let token = UUID()
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = token
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.stateLock.lock()
            self.viewers.removeAll()
            self._port = 0
            self.stateLock.unlock()
        }
    }

    /// 推送一帧 JPEG 到所有观看者。上一帧未写完的观看者只保留最新帧（防积压）。
    func publish(_ jpeg: Data) {
        queue.async { [weak self] in
            guard let self, !self.viewers.isEmpty else { return }
            let payload = Self.multipartFrame(jpeg)
            for id in self.viewers.keys {
                self.enqueue(id: id, data: payload)
            }
        }
    }

    // MARK: - 监听

    private func listen(on preferred: UInt16?, token: UUID) {
        do {
            let candidate = try NWListener(using: .tcp,
                                           on: preferred.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate else { return }
                self.queue.async {
                    guard self.generation == token, self.listener === candidate else { return }
                    switch state {
                    case .ready:
                        guard let actualPort = candidate.port?.rawValue else { return }
                        self.stateLock.lock()
                        self._port = actualPort
                        self.stateLock.unlock()
                        self.log("浏览器查看服务已在端口 \(actualPort) 就绪")
                    case .failed(let error):
                        if preferred != nil, case .posix(.EADDRINUSE) = error {
                            self.log("端口 \(preferred!) 被占用，浏览器服务改用自动端口")
                            candidate.cancel()
                            self.listener = nil
                            self.listen(on: nil, token: token)
                        } else {
                            self.log("浏览器服务失败：\(error.localizedDescription)")
                        }
                    default:
                        break
                    }
                }
            }
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, let candidate, self.listener === candidate,
                      self.connections.count < 16 else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            self.listener = candidate
            candidate.start(queue: queue)
        } catch {
            log("无法创建浏览器服务监听器：\(error.localizedDescription)")
        }
    }

    // MARK: - 连接与 HTTP 解析

    private final class HTTPState {
        var buffer = Data()
    }

    struct Request {
        let method: String
        let target: String
        let body: Data
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let state = HTTPState()
        stateLock.lock()
        connections[id] = connection
        stateLock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connections[id] === connection else { return }
                switch update {
                case .ready:
                    self.receive(connection, id: id, state: state)
                case .failed, .cancelled:
                    self.removeViewer(id)
                    self.connections[id] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, id: UUID, state: HTTPState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connections[id] === connection else { return }
                if let data, !data.isEmpty {
                    state.buffer.append(data)
                    while let (request, consumed) = Self.parse(state.buffer) {
                        state.buffer = Data(state.buffer.dropFirst(consumed))
                        self.handle(request, id: id, connection: connection)
                    }
                    guard state.buffer.count <= 1_048_576 else {
                        connection.cancel()
                        return
                    }
                }
                if complete || error != nil {
                    self.removeViewer(id)
                    self.connections[id] = nil
                    connection.cancel()
                } else {
                    self.receive(connection, id: id, state: state)
                }
            }
        }
    }

    /// 从缓冲解析一条完整 HTTP 消息；不足一条时返回 nil。
    private static func parse(_ buffer: Data) -> (Request, Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength >= 0, contentLength <= 65536 else { return nil }
        let headerBytes = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound)
        let total = headerBytes + contentLength
        guard buffer.count >= total else { return nil }
        let body = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: headerBytes)
                                      ..< buffer.index(buffer.startIndex, offsetBy: total))
        return (Request(method: String(requestLine[0]), target: String(requestLine[1]), body: body), total)
    }

    // MARK: - 路由

    private func handle(_ request: Request, id: UUID, connection: NWConnection) {
        let path = request.target.components(separatedBy: "?")[0]
        switch (request.method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            let body = Data(Self.pageHTML().utf8)
            connection.send(content: Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8",
                                                       body: body), completion: .contentProcessed { _ in })
        case ("GET", "/video.mjpg"):
            registerViewer(id, connection: connection)
            let head = Self.httpResponse(status: "200 OK",
                                         contentType: "multipart/x-mixed-replace; boundary=\(Self.boundary)",
                                         body: Data())
            connection.send(content: head, completion: .contentProcessed { _ in })
        case ("POST", "/touch"):
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                let x = (json["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (json["y"] as? NSNumber)?.doubleValue ?? 0
                let down = (json["down"] as? NSNumber)?.boolValue ?? false
                let pointer = (json["id"] as? NSNumber)?.intValue ?? 1
                DispatchQueue.main.async { [weak self] in
                    self?.onTouch?(pointer, x, y, down)
                }
            }
            connection.send(content: Self.emptyResponse(), completion: .contentProcessed { _ in })
        case ("POST", "/key"):
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let key = json["key"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onKey?(key)
                }
            }
            connection.send(content: Self.emptyResponse(), completion: .contentProcessed { _ in })
        default:
            let body = Data("not found".utf8)
            connection.send(content: Self.httpResponse(status: "404 Not Found", contentType: "text/plain",
                                                       body: body), completion: .contentProcessed { _ in })
        }
    }

    // MARK: - 观看者

    private func registerViewer(_ id: UUID, connection: NWConnection) {
        stateLock.lock()
        viewers[id] = Viewer(id: id, connection: connection)
        let count = viewers.count
        stateLock.unlock()
        log("浏览器已连接画面流（当前 \(count) 个观看者）")
        if count == 1 {
            DispatchQueue.main.async { [weak self] in self?.onViewerCountChanged?(true) }
        }
    }

    private func removeViewer(_ id: UUID) {
        stateLock.lock()
        let existed = viewers.removeValue(forKey: id) != nil
        let count = viewers.count
        stateLock.unlock()
        guard existed else { return }
        log("浏览器画面流已断开（当前 \(count) 个观看者）")
        if count == 0 {
            DispatchQueue.main.async { [weak self] in self?.onViewerCountChanged?(false) }
        }
    }

    private func enqueue(id: UUID, data: Data) {
        guard let viewer = viewers[id] else { return }
        if viewer.writing {
            viewers[id]?.pending = data
            return
        }
        viewers[id]?.writing = true
        viewer.connection.send(content: data, completion: { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.viewers[id] != nil else { return }
                self.viewers[id]?.writing = false
                if error != nil {
                    self.removeViewer(id)
                    return
                }
                if let pending = self.viewers[id]?.pending {
                    self.viewers[id]?.pending = nil
                    self.enqueue(id: id, data: pending)
                }
            }
        })
    }

    // MARK: - 报文构造

    private static func multipartFrame(_ jpeg: Data) -> Data {
        var data = Data()
        data.append(Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8))
        data.append(jpeg)
        data.append(Data("\r\n".utf8))
        return data
    }

    private static func httpResponse(status: String, contentType: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: keep-alive\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func emptyResponse() -> Data {
        httpResponse(status: "204 No Content", contentType: "text/plain", body: Data())
    }

    /// 查看页：深色、画面全宽、底部按键条；pointer 事件转归一化坐标回传。
    private static func pageHTML() -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <title>JiheDrive</title><style>
        body{margin:0;background:#000;display:flex;flex-direction:column;height:100vh;font-family:-apple-system,sans-serif}
        #v{flex:1;width:100%;object-fit:contain;background:#000;touch-action:none}
        #bar{display:flex;gap:8px;padding:10px;background:#111}
        button{flex:1;padding:12px 0;font-size:14px;border:0;border-radius:10px;background:#2a2a2e;color:#fff}
        </style></head><body>
        <img id="v" src="/video.mjpg" draggable="false">
        <div id="bar">
        <button data-key="home">主页</button><button data-key="back">返回</button>
        <button data-key="select">选择</button><button data-key="siri">Siri</button>
        </div>
        <script>
        const v=document.getElementById('v');
        const send=p=>fetch('/touch',{method:'POST',body:JSON.stringify(p)});
        const pos=e=>{const r=v.getBoundingClientRect();return {id:e.pointerId,x:(e.clientX-r.left)/r.width,y:(e.clientY-r.top)/r.height};};
        v.addEventListener('pointerdown',e=>{v.setPointerCapture(e.pointerId);send({...pos(e),down:true});});
        v.addEventListener('pointermove',e=>{if(e.buttons>0){send({...pos(e),down:true});}});
        v.addEventListener('pointerup',e=>send({...pos(e),down:false}));
        v.addEventListener('pointercancel',e=>send({id:e.pointerId,x:0,y:0,down:false}));
        document.querySelectorAll('#bar button').forEach(b=>b.addEventListener('click',()=>fetch('/key',{method:'POST',body:JSON.stringify({key:b.dataset.key})})));
        </script></body></html>
        """
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }
}
