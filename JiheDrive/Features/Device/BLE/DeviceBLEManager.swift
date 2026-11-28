import Foundation
import CoreBluetooth

/// 设备页统一蓝牙中心：扫描、连接、服务发现、特征读写、通知分发、断线重连。
/// 每类设备（DeviceKind）可同时各连一台；同类再连会替换旧的。
/// 所有 CoreBluetooth 回调都在 main queue 上，UI 可直接观察 @Published 状态。
final class DeviceBLEManager: NSObject, ObservableObject {
    static let shared = DeviceBLEManager()

    enum ConnectionState: String {
        case idle
        case scanning
        case connecting
        case discovering
        case connected
        case disconnected
    }

    /// 单路会话状态（一类设备一条）
    private final class Session {
        var device: BLEDevice
        var peripheral: CBPeripheral
        var characteristics: [String: CBCharacteristic] = [:]
        var activeNotify: CBCharacteristic?
        var connectionState: ConnectionState = .idle
        var pendingServices = 0
        var connectContinuation: CheckedContinuation<Void, Error>?
        var notifyContinuation: CheckedContinuation<Void, Error>?
        var writeContinuation: CheckedContinuation<Void, Error>?
        var connectTimeout: DispatchWorkItem?
        var notifyTimeout: DispatchWorkItem?
        var writeTimeout: DispatchWorkItem?
        var autoReconnect = false
        var reconnectTask: Task<Void, Never>?

        init(device: BLEDevice, peripheral: CBPeripheral) {
            self.device = device
            self.peripheral = peripheral
        }
    }

    @Published private(set) var powerState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [BLEDevice] = []
    /// 每类已连接设备（同时多类）
    @Published private(set) var connectedDevices: [DeviceKind: BLEDevice] = [:]
    /// 每类连接状态
    @Published private(set) var connectionStates: [DeviceKind: ConnectionState] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var logs: [String] = []
    @Published var bmsChannel: BMSChannel = {
        let raw = UserDefaults.standard.string(forKey: "device.bms.channel") ?? ""
        return BMSChannel(rawValue: raw) ?? .ffe1
    }() {
        didSet { UserDefaults.standard.set(bmsChannel.rawValue, forKey: "device.bms.channel") }
    }

    private var central: CBCentralManager!
    private var cbPeripherals: [UUID: CBPeripheral] = [:]
    private var sessionsByID: [UUID: Session] = [:]
    private var sessionByKind: [DeviceKind: Session] = [:]
    private var scanTimeout: DispatchWorkItem?
    /// handlerKey → (kind, handler)；通知按外设所属 kind 精确分发
    private var dataHandlers: [String: (kind: DeviceKind, handler: (Data) -> Void)] = [:]
    /// 自动连接防重入：一次开机只尝试一次存档
    private var autoConnectAttempted = false
    private var scanKinds: Set<DeviceKind> = Set(DeviceKind.primaryKinds)

    override init() {
        super.init()
    }

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: ["CBCentralManagerOptionShowPowerPromptKey": false]
        )
    }

    // MARK: - 查询

    /// 任意一类已连接
    var isConnected: Bool { !connectedDevices.isEmpty }

    func isConnected(_ kind: DeviceKind) -> Bool {
        connectionStates[kind] == .connected
    }

    func connectedDevice(for kind: DeviceKind) -> BLEDevice? {
        connectedDevices[kind]
    }

    func connectionState(for kind: DeviceKind) -> ConnectionState {
        connectionStates[kind] ?? .idle
    }

    /// 兼容旧 UI：最近一次/任意一台已连接设备
    var connectedDevice: BLEDevice? {
        if let bms = connectedDevices[.bms] { return bms }
        return connectedDevices.values.first
    }

    /// 兼容旧 UI：优先显示「有连接」或扫描态
    var connectionState: ConnectionState {
        if isScanning { return .scanning }
        if connectedDevices.isEmpty {
            if connectionStates.values.contains(where: { $0 == .connecting || $0 == .discovering }) {
                return .connecting
            }
            return .idle
        }
        return .connected
    }

    func log(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("\(stamp) \(text)")
        if logs.count > 80 { logs.removeFirst(logs.count - 80) }
        MainThreadHangMonitor.note("BLE \(text)")
    }

    func registerDataHandler(_ key: String, kind: DeviceKind, handler: @escaping (Data) -> Void) {
        dataHandlers[key] = (kind, handler)
    }

    /// 兼容旧调用：按常见 key 推断 kind
    func registerDataHandler(_ key: String, handler: @escaping (Data) -> Void) {
        let kind: DeviceKind
        switch key {
        case "bms": kind = .bms
        case "headlight", "motor": kind = .shilanLight
        case "charger": kind = .charger
        case "dianjing": kind = .dianjingMeter
        case "lamp": kind = .lamp
        default: kind = .bms
        }
        registerDataHandler(key, kind: kind, handler: handler)
    }

    func unregisterDataHandler(_ key: String) {
        dataHandlers.removeValue(forKey: key)
    }

    private func publishState() {
        var devices: [DeviceKind: BLEDevice] = [:]
        var states: [DeviceKind: ConnectionState] = [:]
        for (kind, session) in sessionByKind {
            states[kind] = session.connectionState
            if session.connectionState == .connected {
                devices[kind] = session.device
            }
        }
        connectedDevices = devices
        connectionStates = states
        objectWillChange.send()
    }

    // MARK: - 连接记忆（每类一台）

    private static let archiveKey = "device.last.connections"

    private func saveConnectionArchive() {
        var all: [String: [String: String]] = [:]
        for (kind, device) in connectedDevices {
            all[kind.rawValue] = [
                "id": device.id.uuidString,
                "name": device.name,
                "kind": device.kind.rawValue,
                "brand": device.bmsBrand?.rawValue ?? "",
                "lampTransport": device.lampTransport?.rawValue ?? "",
            ]
        }
        UserDefaults.standard.set(all, forKey: Self.archiveKey)
        // 兼容旧单档案
        if let first = connectedDevices.values.first {
            UserDefaults.standard.set([
                "id": first.id.uuidString,
                "name": first.name,
                "kind": first.kind.rawValue,
                "brand": first.bmsBrand?.rawValue ?? "",
                "lampTransport": first.lampTransport?.rawValue ?? "",
            ], forKey: "device.last.connection")
        }
    }

    private func clearConnectionArchive(kind: DeviceKind? = nil) {
        if let kind {
            var all = UserDefaults.standard.dictionary(forKey: Self.archiveKey) as? [String: [String: String]] ?? [:]
            all.removeValue(forKey: kind.rawValue)
            UserDefaults.standard.set(all, forKey: Self.archiveKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.archiveKey)
            UserDefaults.standard.removeObject(forKey: "device.last.connection")
        }
    }

    static func savedConnectionName() -> String? {
        if let all = UserDefaults.standard.dictionary(forKey: archiveKey) as? [String: [String: String]],
           let first = all.values.first,
           let name = first["name"], !name.isEmpty {
            return name
        }
        let archive = UserDefaults.standard.dictionary(forKey: "device.last.connection") as? [String: String]
        return archive?["name"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 启动时回连上次各类设备
    func autoConnectSavedDevice() {
        ensureCentral()
        guard central?.state == .poweredOn, !autoConnectAttempted else { return }
        autoConnectAttempted = true

        var archives: [[String: String]] = []
        if let all = UserDefaults.standard.dictionary(forKey: Self.archiveKey) as? [String: [String: String]] {
            archives = Array(all.values)
        } else if let one = UserDefaults.standard.dictionary(forKey: "device.last.connection") as? [String: String] {
            archives = [one]
        }
        guard !archives.isEmpty else { return }

        for archive in archives {
            guard let idString = archive["id"],
                  let id = UUID(uuidString: idString),
                  let kindRaw = archive["kind"],
                  let kind = DeviceKind(rawValue: kindRaw) else { continue }
            if isConnected(kind) { continue }
            let name = archive["name"] ?? ""
            let brand = archive["brand"].flatMap { BMSBrand(rawValue: $0) }
            let lampTransport = archive["lampTransport"].flatMap { LampTransport(rawValue: $0) }
                ?? (kind == .lamp ? LampTransport.detect(name: name) : nil)
            let device = BLEDevice(id: id, name: name, rssi: 0, kind: kind, bmsBrand: brand, lampTransport: lampTransport)
            log("自动连接上次\(kind.shortTitle)：\(device.displayName)")
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.connect(device)
                    self.log("自动连接\(kind.shortTitle)成功")
                } catch {
                    self.log("自动连接\(kind.shortTitle)失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 扫描

    func startScan(kinds: Set<DeviceKind>? = nil, timeout: TimeInterval = 10) {
        ensureCentral()
        guard central.state == .poweredOn else {
            lastError = DeviceBLEError.bluetoothOff.localizedDescription
            log("扫描失败：\(lastError ?? "")")
            return
        }
        stopScan()
        discovered = []
        lastError = nil
        scanKinds = kinds ?? Set(DeviceKind.primaryKinds)
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: nil)
        let labels = scanKinds.map(\.shortTitle).sorted().joined(separator: "/")
        log("开始扫描（仅 \(labels)，\(Int(timeout))s）")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isScanning else { return }
            self.stopScan()
            self.log("扫描结束 · 发现 \(self.discovered.count) 台")
        }
        scanTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func stopScan() {
        if central?.state == .poweredOn { central?.stopScan() }
        isScanning = false
        scanTimeout?.cancel()
        scanTimeout = nil
    }

    func setKind(_ kind: DeviceKind, for id: UUID) {
        guard let index = discovered.firstIndex(where: { $0.id == id }) else { return }
        discovered[index].kind = kind
    }

    // MARK: - 连接

    func connect(_ device: BLEDevice) async throws {
        try await connectCore(device, enableReconnect: true)
    }

    private func connectCore(_ device: BLEDevice, enableReconnect: Bool) async throws {
        ensureCentral()
        guard central.state == .poweredOn else { throw DeviceBLEError.bluetoothOff }

        // 同类已连同一台 → 直接返回
        if let existing = sessionByKind[device.kind],
           existing.device.id == device.id,
           existing.connectionState == .connected {
            return
        }
        // 同类已连另一台 → 先断旧的（不同类互不影响）
        if let existing = sessionByKind[device.kind], existing.device.id != device.id {
            disconnectSession(existing, keepArchive: false, announce: true)
        }

        let cb = cbPeripherals[device.id]
            ?? central.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let cb else { throw DeviceBLEError.notConnected }

        cb.delegate = self
        cbPeripherals[device.id] = cb
        let session = Session(device: device, peripheral: cb)
        session.autoReconnect = enableReconnect
        session.connectionState = .connecting
        sessionsByID[device.id] = session
        sessionByKind[device.kind] = session
        lastError = nil
        publishState()
        log("连接 \(device.kind.shortTitle)：\(device.displayName)")

        let timer = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session,
                  session.connectionState == .connecting || session.connectionState == .discovering else { return }
            self.failConnect(session, DeviceBLEError.timeout)
            if session.peripheral.state != .disconnected {
                self.central.cancelPeripheralConnection(session.peripheral)
            }
        }
        session.connectTimeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timer)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.connectContinuation = continuation
                central.connect(cb, options: nil)
            }
        } catch {
            session.connectionState = .disconnected
            publishState()
            throw error
        }
        session.connectTimeout?.cancel()
        session.connectTimeout = nil
    }

    func reconnect(_ kind: DeviceKind) async throws {
        guard let device = connectedDevices[kind] ?? sessionByKind[kind]?.device else {
            throw DeviceBLEError.notConnected
        }
        try await connectCore(device, enableReconnect: true)
    }

    /// 兼容：断「任意一台」→ 断全部（旧详情页按钮）；优先用 disconnect(kind:)
    func disconnect() {
        let kinds = Array(sessionByKind.keys)
        for kind in kinds { disconnect(kind) }
    }

    func disconnect(_ kind: DeviceKind) {
        guard let session = sessionByKind[kind] else { return }
        disconnectSession(session, keepArchive: true, announce: true)
        log("已断开\(kind.shortTitle)（保留记忆，下次启动自动回连）")
    }

    func disconnectAndClearAll() {
        let sessions = Array(sessionByKind.values)
        for session in sessions {
            disconnectSession(session, keepArchive: false, announce: false)
        }
        clearConnectionArchive()
        cbPeripherals.removeAll()
        discovered = []
        logs = []
        lastError = nil
        autoConnectAttempted = false
        publishState()
        log("已清除全部蓝牙缓存并断开")
    }

    private func disconnectSession(_ session: Session, keepArchive: Bool, announce: Bool) {
        session.autoReconnect = false
        session.reconnectTask?.cancel()
        session.reconnectTask = nil
        cancelPendingConnect(session)
        let kind = session.device.kind
        if session.peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(session.peripheral)
        }
        sessionsByID.removeValue(forKey: session.device.id)
        if sessionByKind[kind] === session {
            sessionByKind.removeValue(forKey: kind)
        }
        session.characteristics = [:]
        session.activeNotify = nil
        session.connectionState = .idle
        if !keepArchive { clearConnectionArchive(kind: kind) }
        publishState()
        if announce == false { /* silent */ }
    }

    private func failConnect(_ session: Session, _ error: Error) {
        session.connectTimeout?.cancel()
        session.connectTimeout = nil
        let continuation = session.connectContinuation
        session.connectContinuation = nil
        lastError = error.localizedDescription
        continuation?.resume(throwing: error)
    }

    private func cancelPendingConnect(_ session: Session) {
        session.connectTimeout?.cancel()
        session.connectTimeout = nil
        let continuation = session.connectContinuation
        session.connectContinuation = nil
        continuation?.resume(throwing: DeviceBLEError.cancelled)
    }

    private func finishDiscovery(_ session: Session) {
        let kind = session.device.kind
        let preferredNotify: String
        switch kind {
        case .bms:
            preferredNotify = (session.device.bmsBrand == .yanyang)
                ? BMSBrand.yanyang.notifyID
                : bmsChannel.notifyID
        case .shilanLight: preferredNotify = "FFF1"
        case .charger: preferredNotify = "FFE1"
        case .dianjingMeter: preferredNotify = "FF02"
        case .lamp:
            switch lampTransport(session) {
            case .gattFFF0: preferredNotify = "FFF1"
            case .compact: preferredNotify = "FFE1"
            case .gatt2760: preferredNotify = "00002760-08C2-11E1-9073-0E8AC72E0002"
            default: preferredNotify = "FFE2"
            }
        }
        guard let notify = session.characteristics[preferredNotify]
                ?? session.characteristics.values.first(where: { $0.properties.contains(.notify) }) else {
            failConnect(session, DeviceBLEError.characteristicMissing)
            log("特征不匹配：需要 \(preferredNotify)")
            return
        }
        session.activeNotify = notify
        session.notifyTimeout?.cancel()
        let timer = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            let cont = session.notifyContinuation
            session.notifyContinuation = nil
            session.notifyTimeout = nil
            if session.connectContinuation != nil { self.failConnect(session, DeviceBLEError.timeout) }
            cont?.resume(throwing: DeviceBLEError.timeout)
        }
        session.notifyTimeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)

        session.peripheral.setNotifyValue(true, for: notify)
        log("\(kind.shortTitle) 订阅通知 \(Self.shortUUIDKey(notify.uuid))")

        let write = activeWriteCharacteristic(session)
        if let write {
            let mode = write.properties.contains(.writeWithoutResponse) ? "无应答" : "带应答"
            log("\(kind.shortTitle) 写入特征 \(Self.shortUUIDKey(write.uuid))（\(mode)）")
        } else {
            log("\(kind.shortTitle) 写入特征 未找到")
        }
        let summary = session.characteristics.values
            .sorted { Self.shortUUIDKey($0.uuid) < Self.shortUUIDKey($1.uuid) }
            .map { "\(Self.shortUUIDKey($0.uuid))[\(propTags($0))]" }
            .joined(separator: " ")
        log("\(kind.shortTitle) 服务特征：\(summary)")
    }

    private func lampTransport(_ session: Session) -> LampTransport? {
        if let transport = session.device.lampTransport { return transport }
        return LampTransport.detect(name: session.device.name)
    }

    private func activeWriteCharacteristic(_ session: Session) -> CBCharacteristic? {
        let preferred: String
        switch session.device.kind {
        case .bms:
            if session.device.bmsBrand == .yanyang {
                preferred = BMSBrand.yanyang.writeID
            } else {
                preferred = bmsChannel.writeID
            }
        case .shilanLight: preferred = "FFF2"
        case .charger: preferred = "FFE1"
        case .dianjingMeter: preferred = "FF01"
        case .lamp:
            switch lampTransport(session) {
            case .gattFFF0: preferred = "FFF2"
            case .gatt2760: preferred = "00002760-08C2-11E1-9073-0E8AC72E0001"
            default: preferred = "FFE1"
            }
        }
        if let exact = session.characteristics[preferred] { return exact }
        if let notify = session.activeNotify, let chars = notify.service?.characteristics {
            let writable = chars.filter {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
            if let sameService = writable.first(where: { Self.shortUUIDKey($0.uuid) == preferred }) { return sameService }
            if let ffe2 = writable.first(where: { Self.shortUUIDKey($0.uuid) == "FFE2" }) { return ffe2 }
            if let first = writable.first { return first }
        }
        return session.characteristics.values.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
    }

    static func shortUUIDKey(_ uuid: CBUUID) -> String {
        let raw = uuid.uuidString.uppercased()
        guard raw.count == 36 else { return raw }
        let parts = raw.split(separator: "-")
        if parts.count == 5,
           parts[1] == "0000", parts[2] == "1000", parts[3] == "8000",
           parts[4] == "00805F9B34FB", parts[0].hasPrefix("0000") {
            return String(parts[0].suffix(4))
        }
        return raw
    }

    private func propTags(_ c: CBCharacteristic) -> String {
        var tags = ""
        if c.properties.contains(.read) { tags += "读" }
        if c.properties.contains(.write) { tags += tags.isEmpty ? "写" : " 写" }
        if c.properties.contains(.writeWithoutResponse) { tags += " 写无应答" }
        if c.properties.contains(.notify) { tags += " 通知" }
        return tags.isEmpty ? "-" : tags
    }

    // MARK: - BMS 通道

    func selectBMSChannel(_ channel: BMSChannel) async throws {
        guard let session = sessionByKind[.bms], session.peripheral.state == .connected else {
            throw DeviceBLEError.notConnected
        }
        if let old = session.activeNotify, old.uuid.uuidString.uppercased() != channel.notifyID {
            session.peripheral.setNotifyValue(false, for: old)
        }
        guard let notify = session.characteristics[channel.notifyID] else {
            throw DeviceBLEError.characteristicMissing
        }
        bmsChannel = channel
        session.activeNotify = notify
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.notifyContinuation = continuation
            let timer = DispatchWorkItem { [weak session] in
                guard let session else { return }
                let cont = session.notifyContinuation
                session.notifyContinuation = nil
                cont?.resume(throwing: DeviceBLEError.timeout)
            }
            session.notifyTimeout = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
            session.peripheral.setNotifyValue(true, for: notify)
        }
        log("切换到 \(channel.title)")
    }

    // MARK: - 写入

    func write(_ data: Data, kind: DeviceKind, useResponse: Bool = false) async throws {
        guard let session = sessionByKind[kind], session.peripheral.state == .connected else {
            throw DeviceBLEError.notConnected
        }
        guard let characteristic = activeWriteCharacteristic(session) else {
            throw DeviceBLEError.characteristicMissing
        }
        let p = session.peripheral
        let useResponseFinal = useResponse || !characteristic.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = useResponseFinal ? .withResponse : .withoutResponse
        let maxLength = max(20, min(512, p.maximumWriteValueLength(for: type) - 3))
        var offset = 0

        while offset < data.count {
            let length = min(maxLength, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            if useResponseFinal {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.writeContinuation = continuation
                    let timer = DispatchWorkItem { [weak session] in
                        guard let session else { return }
                        let cont = session.writeContinuation
                        session.writeContinuation = nil
                        cont?.resume(throwing: DeviceBLEError.timeout)
                    }
                    session.writeTimeout = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
                    p.writeValue(chunk, for: characteristic, type: type)
                }
            } else {
                p.writeValue(chunk, for: characteristic, type: type)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            offset += length
        }
        log("\(kind.shortTitle) 发送 \(data.count) 字节：\(data.map { String(format: "%02X", $0) }.joined())")
    }

    /// 兼容旧调用：仅一台已连接时可省略 kind
    func write(_ data: Data, useResponse: Bool = false) async throws {
        if connectedDevices.count == 1, let kind = connectedDevices.keys.first {
            try await write(data, kind: kind, useResponse: useResponse)
            return
        }
        throw DeviceBLEError.notConnected
    }

    private func finishWrite(_ session: Session, _ error: Error?) {
        session.writeTimeout?.cancel()
        session.writeTimeout = nil
        let continuation = session.writeContinuation
        session.writeContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    // MARK: - 断线重连

    private func scheduleReconnect(_ session: Session) {
        guard session.autoReconnect else { return }
        let device = session.device
        session.reconnectTask?.cancel()
        session.reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.connectionStates[device.kind] != .connected else { return }
                do {
                    try await self.connectCore(device, enableReconnect: true)
                    self.log("\(device.kind.shortTitle) 自动重连成功")
                    return
                } catch {
                    self.log("\(device.kind.shortTitle) 自动重连 \(attempt)/5 失败")
                }
            }
            self.log("\(device.kind.shortTitle) 自动重连已达上限")
        }
    }

    private func session(for peripheral: CBPeripheral) -> Session? {
        sessionsByID[peripheral.identifier] ?? sessionByKind.values.first { $0.peripheral === peripheral }
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        powerState = central.state
        if central.state != .poweredOn {
            lastError = DeviceBLEError.bluetoothOff.localizedDescription
            stopScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        guard let kind = DeviceKind.classify(name: name, serviceUUIDs: services) else { return }
        guard scanKinds.contains(kind) else { return }

        cbPeripherals[peripheral.identifier] = peripheral
        let device = BLEDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            kind: kind,
            bmsBrand: kind == .bms ? BMSBrand.detect(name: name) : nil,
            lampTransport: kind == .lamp ? LampTransport.detect(name: name) : nil
        )
        if let index = discovered.firstIndex(where: { $0.id == device.id }) {
            var old = discovered[index]
            old.rssi = device.rssi
            if old.name.isEmpty, !device.name.isEmpty { old.name = device.name }
            discovered[index] = old
            discovered.sort { $0.rssi > $1.rssi }
        } else {
            discovered.append(device)
            discovered.sort { $0.rssi > $1.rssi }
            log("发现 \(device.kind.shortTitle)：\(device.displayName)（\(device.rssi) dBm）")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session = session(for: peripheral) else { return }
        session.connectionState = .discovering
        session.characteristics = [:]
        publishState()
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let session = session(for: peripheral) else { return }
        failConnect(session, error ?? DeviceBLEError.notConnected)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let session = session(for: peripheral) else { return }
        let wasConnected = session.connectionState == .connected
        session.connectionState = .disconnected
        session.characteristics = [:]
        session.activeNotify = nil
        failConnect(session, DeviceBLEError.notConnected)
        publishState()
        if wasConnected {
            log("\(session.device.kind.shortTitle) 断开\(error.map { "：\($0.localizedDescription)" } ?? "")")
        }
        scheduleReconnect(session)
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let session = session(for: peripheral) else { return }
        if let error {
            failConnect(session, error)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            failConnect(session, DeviceBLEError.characteristicMissing)
            return
        }
        session.pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let session = session(for: peripheral) else { return }
        if let error {
            failConnect(session, error)
            return
        }
        for characteristic in service.characteristics ?? [] {
            session.characteristics[Self.shortUUIDKey(characteristic.uuid)] = characteristic
        }
        session.pendingServices -= 1
        if session.pendingServices <= 0 { finishDiscovery(session) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let session = session(for: peripheral) else { return }
        guard let active = session.activeNotify, characteristic.uuid == active.uuid else { return }
        session.notifyTimeout?.cancel()
        session.notifyTimeout = nil
        let continuation = session.notifyContinuation
        session.notifyContinuation = nil
        if let error {
            lastError = error.localizedDescription
            if session.connectContinuation != nil { failConnect(session, error) }
            continuation?.resume(throwing: error)
            return
        }
        if characteristic.isNotifying, session.connectContinuation != nil {
            session.connectionState = .connected
            let cont = session.connectContinuation
            session.connectContinuation = nil
            cont?.resume()
            publishState()
            saveConnectionArchive()
            log("\(session.device.kind.shortTitle) 连接就绪")
        }
        continuation?.resume()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("通知错误：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        guard let session = session(for: peripheral) else { return }
        let kind = session.device.kind
        for entry in dataHandlers.values where entry.kind == kind {
            entry.handler(data)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let session = session(for: peripheral) else { return }
        finishWrite(session, error)
    }
}
