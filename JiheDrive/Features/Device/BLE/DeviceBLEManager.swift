import Foundation
import CoreBluetooth

/// 设备页统一蓝牙中心：扫描、连接、服务发现、特征读写、通知分发、断线重连。
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

    @Published private(set) var powerState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [BLEDevice] = []
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var connectedDevice: BLEDevice?
    @Published private(set) var lastError: String?
    @Published private(set) var logs: [String] = []
    @Published var bmsChannel: BMSChannel = {
        let raw = UserDefaults.standard.string(forKey: "device.bms.channel") ?? ""
        return BMSChannel(rawValue: raw) ?? .ffe1
    }() {
        didSet { UserDefaults.standard.set(bmsChannel.rawValue, forKey: "device.bms.channel") }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cbPeripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]
    private var activeNotify: CBCharacteristic?
    private var pendingServices = 0

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeout: DispatchWorkItem?
    private var notifyTimeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?

    private var autoReconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var dataHandlers: [String: (Data) -> Void] = [:]
    /// 自动连接防重入：一次开机只尝试一次存档设备
    private var autoConnectAttempted = false

    override init() {
        super.init()
        // 故意不在这里创建 CBCentralManager：蓝牙权限弹窗应出现在
        // 用户真正「扫描/连接蓝牙」时，而不是 App 启动进首页时
    }

    /// 惰性创建中央管理器（首次扫描/连接时触发蓝牙权限请求）
    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: ["CBCentralManagerOptionShowPowerPromptKey": false]
        )
    }

    // MARK: - 工具

    var isConnected: Bool { connectionState == .connected }

    func log(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("\(stamp) \(text)")
        if logs.count > 80 { logs.removeFirst(logs.count - 80) }
    }

    func registerDataHandler(_ key: String, handler: @escaping (Data) -> Void) {
        dataHandlers[key] = handler
    }

    func unregisterDataHandler(_ key: String) {
        dataHandlers.removeValue(forKey: key)
    }

    /// 当前扫描允许的设备类型；nil = 主推类型（保护板 + 石栏）
    private var scanKinds: Set<DeviceKind> = Set(DeviceKind.primaryKinds)

    private func activeWriteCharacteristic() -> CBCharacteristic? {
        let preferred: String
        switch connectedDevice?.kind {
        case .bms:
            // 彦阳写 FFE2；蚂蚁默认走通道写特征（FFE1 / FFF3 / FFF5）
            if connectedDevice?.bmsBrand == .yanyang {
                preferred = BMSBrand.yanyang.writeID
            } else {
                preferred = bmsChannel.writeID
            }
        case .shilanLight: preferred = "FFF2"
        case .none: preferred = ""
        }
        if let exact = characteristics[preferred] { return exact }
        // 部分固件把 FFE1/FFE2 以 128 位形式暴露，iOS 不折叠成短码，
        // 存 key 时已做归一化；这里再加同服务兜底，避免挑中 OTA/DFU 等无关通道
        if let notify = activeNotify, let chars = notify.service?.characteristics {
            let writable = chars.filter {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
            if let sameService = writable.first(where: { Self.shortUUIDKey($0.uuid) == preferred }) { return sameService }
            if let ffe2 = writable.first(where: { Self.shortUUIDKey($0.uuid) == "FFE2" }) { return ffe2 }
            if let first = writable.first { return first }
        }
        return characteristics.values.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
    }

    /// CBUUID 短码：0000XXXX-0000-1000-8000-00805F9B34FB 形式折叠回 XXXX。
    /// 彦阳 YY-AE4S 实测以 128 位暴露 FFE0/FFE1，iOS 的 uuidString 不自动折叠，
    /// 直接用原始串做 key 会查不到 "FFE2"，写帧就进了错误的特征。
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

    /// 特征属性速记（发现日志用）
    private func propTags(_ c: CBCharacteristic) -> String {
        var tags = ""
        if c.properties.contains(.read) { tags += "读" }
        if c.properties.contains(.write) { tags += tags.isEmpty ? "写" : " 写" }
        if c.properties.contains(.writeWithoutResponse) { tags += " 写无应答" }
        if c.properties.contains(.notify) { tags += " 通知" }
        return tags.isEmpty ? "-" : tags
    }

    // MARK: - 连接记忆（下次启动自动重连）

    private static let archiveKey = "device.last.connection"

    /// 连接成功后存档：id/名称/类型/品牌，下次启动自动回连
    private func saveConnectionArchive() {
        guard let device = connectedDevice else { return }
        let archive: [String: String] = [
            "id": device.id.uuidString,
            "name": device.name,
            "kind": device.kind.rawValue,
            "brand": device.bmsBrand?.rawValue ?? "",
        ]
        UserDefaults.standard.set(archive, forKey: Self.archiveKey)
    }

    private func clearConnectionArchive() {
        UserDefaults.standard.removeObject(forKey: Self.archiveKey)
    }

    static func savedConnectionName() -> String? {
        let archive = UserDefaults.standard.dictionary(forKey: archiveKey) as? [String: String]
        return archive?["name"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 启动时回连上次设备：无需扫描，直接 retrievePeripherals + connect
    func autoConnectSavedDevice() {
        ensureCentral()
        guard central?.state == .poweredOn, connectionState == .idle, !autoConnectAttempted else { return }
        guard let archive = UserDefaults.standard.dictionary(forKey: Self.archiveKey) as? [String: String],
              let idString = archive["id"],
              let id = UUID(uuidString: idString),
              let kindRaw = archive["kind"],
              let kind = DeviceKind(rawValue: kindRaw) else { return }
        autoConnectAttempted = true
        let name = archive["name"] ?? ""
        let brand = archive["brand"].flatMap { BMSBrand(rawValue: $0) }
        let device = BLEDevice(id: id, name: name, rssi: 0, kind: kind, bmsBrand: brand)
        log("自动连接上次设备：\(device.displayName)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connect(device)
                self.log("自动连接成功")
            } catch {
                self.log("自动连接失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 扫描

    /// - Parameters:
    ///   - kinds: 只保留这些类型；默认保护板 + 石栏，避免满屏无关 BLE。
    ///   - timeout: 默认 10 秒；设备广播间隔约 100ms~1s，正常 1~2 秒内就会出现在列表。
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
        connectionState = .scanning
        // 不按 UUID 限扫：部分石栏/ANT 广播不含服务 UUID；靠名称过滤即可。
        // AllowDuplicates 必须关：开着的话同一设备的每个广播包都会触发回调，
        // 主线程被发现回调+排序刷满，表现为「扫描很卡、列表抖动」。
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
        if connectionState == .scanning { connectionState = .idle }
    }

    /// 对扫描结果手动归类：广播名猜错时可从 UI 纠正
    func setKind(_ kind: DeviceKind, for id: UUID) {
        guard let index = discovered.firstIndex(where: { $0.id == id }) else { return }
        discovered[index].kind = kind
    }

    // MARK: - 连接

    func connect(_ device: BLEDevice) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        autoReconnect = true
        try await connectCore(device)
    }

    private func connectCore(_ device: BLEDevice) async throws {
        ensureCentral()
        guard central.state == .poweredOn else { throw DeviceBLEError.bluetoothOff }

        if let current = peripheral, current.identifier == device.id, connectionState == .connected {
            return
        }
        if let current = peripheral, current.identifier != device.id, current.state != .disconnected {
            central.cancelPeripheralConnection(current)
        }

        let cb = cbPeripherals[device.id]
            ?? central.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let cb else { throw DeviceBLEError.notConnected }

        cb.delegate = self
        peripheral = cb
        cbPeripherals[device.id] = cb
        connectedDevice = device
        characteristics = [:]
        activeNotify = nil
        lastError = nil
        connectionState = .connecting
        log("连接 \(device.displayName)")

        connectTimeout?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .connecting || self.connectionState == .discovering else { return }
            self.failConnect(DeviceBLEError.timeout)
            if cb.state != .disconnected { self.central.cancelPeripheralConnection(cb) }
        }
        connectTimeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timer)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectContinuation = continuation
                central.connect(cb, options: nil)
            }
        } catch {
            connectionState = .disconnected
            throw error
        }
        connectTimeout?.cancel()
        connectTimeout = nil
    }

    func reconnect() async throws {
        guard let device = connectedDevice else { throw DeviceBLEError.notConnected }
        try await connectCore(device)
    }

    func disconnect() {
        autoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelPendingConnect()
        guard let p = peripheral else {
            connectionState = .idle
            connectedDevice = nil
            return
        }
        if p.state != .disconnected { central.cancelPeripheralConnection(p) }
        peripheral = nil
        connectedDevice = nil
        characteristics = [:]
        activeNotify = nil
        clearConnectionArchive()
        connectionState = .idle
        log("已断开连接")
    }

    private func failConnect(_ error: Error) {
        connectTimeout?.cancel()
        connectTimeout = nil
        let continuation = connectContinuation
        connectContinuation = nil
        lastError = error.localizedDescription
        continuation?.resume(throwing: error)
    }

    /// 主动断开时不把「已取消」写成错误提示
    private func cancelPendingConnect() {
        connectTimeout?.cancel()
        connectTimeout = nil
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?.resume(throwing: DeviceBLEError.cancelled)
    }

    private func finishDiscovery() {
        guard let kind = connectedDevice?.kind else {
            failConnect(DeviceBLEError.characteristicMissing)
            return
        }
        let preferredNotify: String
        if kind == .bms {
            preferredNotify = (connectedDevice?.bmsBrand == .yanyang)
                ? BMSBrand.yanyang.notifyID
                : bmsChannel.notifyID
        } else {
            preferredNotify = "FFF1"
        }
        guard let notify = characteristics[preferredNotify]
                ?? characteristics.values.first(where: { $0.properties.contains(.notify) }) else {
            failConnect(DeviceBLEError.characteristicMissing)
            log("特征不匹配：需要 \(preferredNotify)")
            return
        }
        activeNotify = notify
        notifyTimeout?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let cont = self.notifyContinuation
            self.notifyContinuation = nil
            self.notifyTimeout = nil
            if self.connectContinuation != nil { self.failConnect(DeviceBLEError.timeout) }
            cont?.resume(throwing: DeviceBLEError.timeout)
        }
        notifyTimeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)

        peripheral?.setNotifyValue(true, for: notify)
        log("订阅通知 \(Self.shortUUIDKey(notify.uuid))")

        let write = activeWriteCharacteristic()
        if let write {
            let mode = write.properties.contains(.writeWithoutResponse) ? "无应答" : "带应答"
            log("写入特征 \(Self.shortUUIDKey(write.uuid))（\(mode)）")
        } else {
            log("写入特征 未找到")
        }
        let summary = characteristics.values
            .sorted { Self.shortUUIDKey($0.uuid) < Self.shortUUIDKey($1.uuid) }
            .map { "\(Self.shortUUIDKey($0.uuid))[\(propTags($0))]" }
            .joined(separator: " ")
        log("服务特征：\(summary)")
    }

    /// BMS 通道切换：先关旧通知，再订阅新特征
    func selectBMSChannel(_ channel: BMSChannel) async throws {
        guard let p = peripheral, p.state == .connected else { throw DeviceBLEError.notConnected }
        if let old = activeNotify, old.uuid.uuidString.uppercased() != channel.notifyID {
            p.setNotifyValue(false, for: old)
        }
        guard let notify = characteristics[channel.notifyID] else {
            throw DeviceBLEError.characteristicMissing
        }
        bmsChannel = channel
        activeNotify = notify
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            notifyContinuation = continuation
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let cont = self.notifyContinuation
                self.notifyContinuation = nil
                cont?.resume(throwing: DeviceBLEError.timeout)
            }
            notifyTimeout = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
            p.setNotifyValue(true, for: notify)
        }
        log("切换到 \(channel.title)")
    }

    // MARK: - 写入

    /// 按 iOS 当前 MTU 自动分片；无应答写入片间留 20ms，避免设备丢包
    func write(_ data: Data, useResponse: Bool = false) async throws {
        guard let p = peripheral, p.state == .connected else { throw DeviceBLEError.notConnected }
        guard let characteristic = activeWriteCharacteristic() else { throw DeviceBLEError.characteristicMissing }

        // 特征只支持带应答写入时必须用 .withResponse：
        // 对仅有 .write 属性的特征发 .withoutResponse 会被 CoreBluetooth 静默丢弃（不报错、设备收不到）
        let useResponseFinal = useResponse || !characteristic.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = useResponseFinal ? .withResponse : .withoutResponse
        let maxLength = max(20, min(512, p.maximumWriteValueLength(for: type) - 3))
        var offset = 0

        while offset < data.count {
            let length = min(maxLength, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            if useResponseFinal {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    writeContinuation = continuation
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        let cont = self.writeContinuation
                        self.writeContinuation = nil
                        cont?.resume(throwing: DeviceBLEError.timeout)
                    }
                    writeTimeout = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
                    p.writeValue(chunk, for: characteristic, type: type)
                }
            } else {
                p.writeValue(chunk, for: characteristic, type: type)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            offset += length
        }
        log("发送 \(data.count) 字节：\(data.map { String(format: "%02X", $0) }.joined())")
    }

    private func finishWrite(_ error: Error?) {
        writeTimeout?.cancel()
        writeTimeout = nil
        let continuation = writeContinuation
        writeContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    // MARK: - 断线重连

    private func scheduleReconnect() {
        guard autoReconnect, let device = connectedDevice else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.autoReconnect, !Task.isCancelled else { return }
                guard self.connectionState != .connected else { return }
                do {
                    try await self.connectCore(device)
                    self.log("自动重连成功")
                    return
                } catch {
                    self.log("自动重连 \(attempt)/5 失败")
                }
            }
            self.autoReconnect = false
            self.log("自动重连已达上限")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        powerState = central.state
        if central.state != .poweredOn {
            lastError = DeviceBLEError.bluetoothOff.localizedDescription
            failConnect(DeviceBLEError.bluetoothOff)
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
        // 无名 + 无法分类 = 噪声，直接丢弃（这是扫描变慢、列表太脏的主因）
        guard let kind = DeviceKind.classify(name: name, serviceUUIDs: services) else { return }
        guard scanKinds.contains(kind) else { return }

        cbPeripherals[peripheral.identifier] = peripheral
        let device = BLEDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            kind: kind,
            bmsBrand: kind == .bms ? BMSBrand.detect(name: name) : nil
        )
        if let index = discovered.firstIndex(where: { $0.id == device.id }) {
            var old = discovered[index]
            old.rssi = device.rssi
            if old.name.isEmpty, !device.name.isEmpty { old.name = device.name }
            discovered[index] = old
            // 信号变强时上浮，方便点最近的那台
            discovered.sort { $0.rssi > $1.rssi }
        } else {
            discovered.append(device)
            discovered.sort { $0.rssi > $1.rssi }
            log("发现 \(device.kind.shortTitle)：\(device.displayName)（\(device.rssi) dBm）")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        connectionState = .discovering
        characteristics = [:]
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        failConnect(error ?? DeviceBLEError.notConnected)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let wasConnected = connectionState == .connected
        connectionState = .disconnected
        characteristics = [:]
        activeNotify = nil
        failConnect(DeviceBLEError.notConnected)
        if wasConnected { log("设备断开\(error.map { "：\($0.localizedDescription)" } ?? "")") }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failConnect(error)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            failConnect(DeviceBLEError.characteristicMissing)
            return
        }
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            failConnect(error)
            return
        }
        for characteristic in service.characteristics ?? [] {
            // 归一化成短码 key：128 位暴露的 FFE1/FFE2 也能按短码命中
            characteristics[Self.shortUUIDKey(characteristic.uuid)] = characteristic
        }
        pendingServices -= 1
        if pendingServices <= 0 { finishDiscovery() }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // 通道切换时会先关闭旧特征；旧特征的状态回调不能误消费新特征的 continuation
        guard let active = activeNotify, characteristic.uuid == active.uuid else { return }
        notifyTimeout?.cancel()
        notifyTimeout = nil
        let continuation = notifyContinuation
        notifyContinuation = nil
        if let error {
            lastError = error.localizedDescription
            if connectContinuation != nil { failConnect(error) }
            continuation?.resume(throwing: error)
            return
        }
        if characteristic.isNotifying, connectContinuation != nil {
            connectionState = .connected
            let cont = connectContinuation
            connectContinuation = nil
            cont?.resume()
            saveConnectionArchive()
            log("连接就绪")
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
        for handler in dataHandlers.values { handler(data) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        finishWrite(error)
    }
}
