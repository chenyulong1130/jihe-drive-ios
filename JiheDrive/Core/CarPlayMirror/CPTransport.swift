import Foundation
import ObjectiveC.runtime

/// CoreAccessories 私有框架桥：让本机 iOS 把 App 当作「已连接的 Wi-Fi 配件」，
/// 从而在直连传输上跑 iAP2 会话（同机 CarPlay 的入口）。
///
/// 参数与调用序严格对齐 CarWithin 的 DirectAccessoryTransport.m：
///   client      = [ACCTransportClient sharedClient]
///   connection  = [client createConnectionWithType:2 andIdentifier:<id>]   ← 返回连接标识
///   endpoint    = [client createEndpointWithTransportType:2 andProtocol:4
///                    andIdentifier:nil andDataOutHandler:<block 3 参数>
///                    forConnectionWithUUID:<connection> publishConnection:YES]
///   发送(App→iOS)  = [client processIncomingData:<data> forEndpointWithUUID:<endpoint>]
///   接收(iOS→App) = dataOutHandler 第 3 个参数（NSData）
///   销毁           = destroyEndpointWithUUID:<endpoint> / destroyConnectionWithUUID:<connection>
/// 之前把新生成的 UUID 当作 connection/endpoint 标识传入，框架会以「拒绝发布」回应。
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
                return "CoreAccessories 拒绝了\(what)（连接标识/回调签名不匹配，或当前签名无私有传输权限）"
            case .sendFailure:
                return "直连传输写入失败"
            }
        }
        var description: String { errorDescription ?? "传输错误" }
    }

    var onData: ((Data) -> Void)?

    private var client: AnyObject?
    private var connection: AnyObject?   /// createConnectionWithType: 返回的连接标识
    private var endpoint: AnyObject?     /// createEndpointWith… 返回的端点标识
    private var generation = UUID()
    private var dataOutHandlerBox: Any?
    private(set) var isActive = false

    private static var cachedClient: AnyObject?

    /// NSObject 侧的方法签名校验（CarWithin 的 HasMethod 等价实现）。
    private static func hasMethod(_ object: AnyObject, _ name: String, _ arguments: Int) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let target = object as? NSObject, target.responds(to: selector) else { return false }
        // Swift 无法调用 NSObject.methodSignature(for:)，直接用 runtime 读取 selector 的参数个数。
        guard let method = class_getInstanceMethod(object_getClass(target), selector) else { return false }
        return method_getNumberOfArguments(method) == UInt32(arguments + 2)
    }

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
        guard transportType == 2 || transportType == 8 else {
            throw TransportError.refused("不支持的传输类型")
        }
        let client = try Self.acquireClient()

        let createName = "createConnectionWithType:andIdentifier:"
        guard Self.hasMethod(client, createName, 2) else {
            throw TransportError.methodMissing(createName)
        }
        let createSelector = NSSelectorFromString(createName)
        let createConnectionMethod = class_getInstanceMethod(object_getClass(client), createSelector)
        typealias CreateConnectionFn = @convention(c) (AnyObject, Selector, Int, AnyObject?) -> Unmanaged<AnyObject>?
        var connectionObject: AnyObject?
        if let imp = createConnectionMethod.map({ method_getImplementation($0) }) {
            let fn = unsafeBitCast(imp, to: CreateConnectionFn.self)
            connectionObject = fn(client, createSelector, 2, identifier as AnyObject)?
                .takeUnretainedValue()
            // 类型 2 失败时退回类型 1
            if connectionObject == nil {
                connectionObject = fn(client, createSelector, 1, identifier as AnyObject)?
                    .takeUnretainedValue()
            }
        }
        guard let connection = connectionObject else {
            throw TransportError.refused("连接创建")
        }
        self.connection = connection

        let endpointName = "createEndpointWithTransportType:andProtocol:andIdentifier:"
            + "andDataOutHandler:forConnectionWithUUID:publishConnection:"
        guard Self.hasMethod(client, endpointName, 6) else {
            throw TransportError.methodMissing(endpointName)
        }

        let generation = UUID()
        self.generation = generation
        // 回调是 3 个参数（来源 NSString / 目标 NSString / 数据 NSData），
        // 数据固定取第 3 个；用 1 参数 block 会读错寄存器里的对象。
        let dataOutHandler: @convention(block) (AnyObject?, AnyObject?, NSData?) -> Void = { [weak self] _, _, data in
            guard let data, data.count <= 65536 else { return }
            let copy = data as Data
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == generation else { return }
                self.onData?(copy)
            }
        }
        let handlerObject = unsafeBitCast(dataOutHandler, to: AnyObject.self)
        self.dataOutHandlerBox = handlerObject

        let endpointSelector = NSSelectorFromString(endpointName)
        guard let endpointMethod = class_getInstanceMethod(object_getClass(client), endpointSelector) else {
            throw TransportError.methodMissing(endpointName)
        }
        typealias CreateEndpointFn = @convention(c) (AnyObject, Selector, Int, Int, AnyObject?, AnyObject?, AnyObject?, Bool) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(endpointMethod), to: CreateEndpointFn.self)
        // forConnectionWithUUID 必须是 createConnectionWithType 返回的连接标识，
        // 不能是新生成的 UUID——否则框架直接拒绝发布 iAP2 endpoint。
        let endpointObject = fn(client, endpointSelector, transportType, 4,
                                nil, handlerObject, connection, true)?
            .takeUnretainedValue()
        guard let endpointObject else {
            self.connection = nil
            self.dataOutHandlerBox = nil
            throw TransportError.refused("iAP2 endpoint 发布")
        }

        self.client = client
        self.endpoint = endpointObject
        self.isActive = true
    }

    /// 向本机 iOS 发送数据（配件 → 手机方向）。
    func send(_ data: Data) throws {
        guard let client, let endpoint, isActive else { throw TransportError.sendFailure }
        let selector = NSSelectorFromString("processIncomingData:forEndpointWithUUID:")
        guard Self.hasMethod(client, "processIncomingData:forEndpointWithUUID:", 2) else {
            throw TransportError.methodMissing("processIncomingData:forEndpointWithUUID:")
        }
        guard let nsClient = client as? NSObject else { throw TransportError.sendFailure }
        nsClient.perform(selector, with: data, with: endpoint)
    }

    func stop() {
        if let client, let endpoint,
           Self.hasMethod(client, "destroyEndpointWithUUID:", 1),
           let nsClient = client as? NSObject {
            nsClient.perform(NSSelectorFromString("destroyEndpointWithUUID:"), with: endpoint)
        }
        if let client, let connection,
           Self.hasMethod(client, "destroyConnectionWithUUID:", 1),
           let nsClient = client as? NSObject {
            nsClient.perform(NSSelectorFromString("destroyConnectionWithUUID:"), with: connection)
        }
        isActive = false
        generation = UUID()
        client = nil
        connection = nil
        endpoint = nil
        dataOutHandlerBox = nil
        onData = nil
    }

    deinit { stop() }
}
