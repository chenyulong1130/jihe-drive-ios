import Foundation
import ObjectiveC.runtime

/// CoreAccessories 私有框架桥：让本机 iOS 把 App 当作「已连接的 Wi-Fi 配件」，
/// 从而在直连传输上跑 iAP2 会话（同机 CarPlay 的入口）。
///
/// 调用面（iOS 16–26 实测有效，系统升级需重新验证）：
///   client      = [ACCTransportClient sharedClient]
///   connection  = [client createConnectionWithType:2 andIdentifier:<id>]
///   endpoint    = [client createEndpointWithTransportType:2 andProtocol:4
///                    andIdentifier:nil andDataOutHandler:<block>
///                    forConnectionWithUUID:<uuid> publishConnection:YES]
///   发送(App→iOS)  = [client processIncomingData:<data> forEndpointWithUUID:<uuid>]
///   接收(iOS→App)  = dataOutHandler 回调（≤16KB/块）
///   销毁           = destroyEndpointWithUUID / destroyConnectionWithUUID
final class CPDirectAccessoryTransport {

    enum TransportError: LocalizedError, CustomStringConvertible {
        case frameworkUnavailable
        case methodMissing(String)
        case refused(String)
        case sendFailure

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable:
                return "CoreAccessories ACCTransportClient 在此系统版本不可用"
            case .methodMissing(let what):
                return "CoreAccessories 传输方法已变化：\(what)"
            case .refused(let what):
                return "CoreAccessories 拒绝了\(what)（当前签名可能无私有传输权限）"
            case .sendFailure:
                return "直连传输写入失败"
            }
        }
        var description: String { errorDescription ?? "传输错误" }
    }

    var onData: ((Data) -> Void)?

    private var client: AnyObject?
    private var connection: AnyObject?
    private var endpointUUID: UUID?
    private var dataOutHandlerBox: Any?
    private(set) var isActive = false

    private static var cachedClient: AnyObject?

    /// 加载 CoreAccessories 框架并取出共享 client。
    private static func acquireClient() throws -> AnyObject {
        if let cached = cachedClient { return cached }
        let frameworkPath = "/System/Library/PrivateFrameworks/CoreAccessories.framework"
        guard let bundle = Bundle(path: frameworkPath), bundle.load() else {
            throw TransportError.frameworkUnavailable
        }
        guard let cls = NSClassFromString("ACCTransportClient") else {
            throw TransportError.frameworkUnavailable
        }
        let sharedSelector = NSSelectorFromString("sharedClient")
        typealias SharedFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let sharedImp = class_getClassMethod(cls, sharedSelector).map({ method_getImplementation($0) }) else {
            throw TransportError.methodMissing("sharedClient")
        }
        let sharedFn = unsafeBitCast(sharedImp, to: SharedFn.self)
        guard let client = sharedFn(cls, sharedSelector)?.takeUnretainedValue() else {
            throw TransportError.methodMissing("sharedClient")
        }
        cachedClient = client
        return client
    }

    /// 建立配件端点。`identifier` 是连接标识（用本机稳定 deviceID）。
    func start(withIdentifier identifier: String, transportType: Int) throws {
        stop()
        let client = try Self.acquireClient()

        // connection = [client createConnectionWithType:<type> andIdentifier:<id>]
        let createConnectionSelector = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        guard client.responds(to: createConnectionSelector) else {
            throw TransportError.methodMissing("createConnectionWithType:andIdentifier:")
        }
        let createConnectionMethod = class_getInstanceMethod(object_getClass(client), createConnectionSelector)
        typealias CreateConnectionFn = @convention(c) (AnyObject, Selector, Int, AnyObject?) -> Unmanaged<AnyObject>?
        var connectionObject: AnyObject?
        if let imp = createConnectionMethod.map({ method_getImplementation($0) }) {
            let fn = unsafeBitCast(imp, to: CreateConnectionFn.self)
            connectionObject = fn(client, createConnectionSelector, transportType, identifier as AnyObject)?
                .takeUnretainedValue()
            if connectionObject == nil {
                // 类型 2 失败时退回类型 1
                connectionObject = fn(client, createConnectionSelector, 1, identifier as AnyObject)?
                    .takeUnretainedValue()
            }
        }
        guard let connection = connectionObject else {
            throw TransportError.refused("连接创建")
        }

        let generation = UUID()
        let dataOutHandler: @convention(block) (NSData) -> Void = { [weak self] data in
            guard let self else { return }
            self.onData?(data as Data)
        }
        // 块对象与 UUID 装箱为 ObjC 对象传入 IMP；同时持有块防释放
        let handlerObject = unsafeBitCast(dataOutHandler, to: AnyObject.self)
        self.dataOutHandlerBox = handlerObject

        // endpoint = [client createEndpointWithTransportType:2 andProtocol:4 andIdentifier:nil
        //             andDataOutHandler:<block> forConnectionWithUUID:<uuid> publishConnection:YES]
        let createEndpointSelector = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:"
            + "forConnectionWithUUID:publishConnection:")
        guard client.responds(to: createEndpointSelector) else {
            throw TransportError.methodMissing("createEndpointWithTransportType:…")
        }
        let createEndpointMethod = class_getInstanceMethod(type(of: client), createEndpointSelector)
        typealias CreateEndpointFn = @convention(c) (AnyObject, Selector, Int, Int, AnyObject?, AnyObject?, AnyObject?, Bool) -> Unmanaged<AnyObject>?
        var endpointObject: AnyObject?
        if let imp = createEndpointMethod.map({ method_getImplementation($0) }) {
            let fn = unsafeBitCast(imp, to: CreateEndpointFn.self)
            endpointObject = fn(client, createEndpointSelector, transportType, 4, NSNull(),
                                handlerObject, generation as NSUUID, true)?.takeUnretainedValue()
        }
        guard let endpoint = endpointObject else {
            throw TransportError.refused("iAP2 endpoint 发布")
        }

        self.client = client
        self.connection = connection
        self.endpointUUID = generation
        self.isActive = true
        _ = endpoint // 保留 endpoint 引用（框架以 UUID 索引，防提前释放）
    }

    /// 向本机 iOS 发送数据（配件 → 手机方向）。
    func send(_ data: Data) throws {
        guard let client, let endpointUUID, isActive else { throw TransportError.sendFailure }
        let selector = NSSelectorFromString("processIncomingData:forEndpointWithUUID:")
        guard client.responds(to: selector) else {
            throw TransportError.methodMissing("processIncomingData:forEndpointWithUUID:")
        }
        guard let nsClient = client as? NSObject else { throw TransportError.sendFailure }
        nsClient.perform(selector, with: data, with: endpointUUID)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if let client {
            if let endpointUUID {
                let destroyEndpoint = NSSelectorFromString("destroyEndpointWithUUID:")
                if client.responds(to: destroyEndpoint) {
                    client.perform(destroyEndpoint, with: endpointUUID)
                }
            }
            if connection != nil {
                let destroyConnection = NSSelectorFromString("destroyConnectionWithUUID:")
                if client.responds(to: destroyConnection) {
                    client.perform(destroyConnection)
                }
            }
        }
        client = nil
        connection = nil
        endpointUUID = nil
        dataOutHandlerBox = nil
        onData = nil
    }

    deinit { stop() }
}
