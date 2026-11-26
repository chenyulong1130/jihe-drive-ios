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

    override init() {
        super.init()
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
        case .shilanLight, .controller: preferred = "FFF2"
        case .none: preferred = ""
        }
        if let exact = characteristics[preferred] { return exact }
        // 彦阳兜底：FFE2 找不到时试 FFE1
        if connectedDevice?.bmsBrand == .yanyang, let fallback = characteristics["FFE1"] {
            return fallback
        }
        return characteristics.values.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
    }

    // MARK: - 扫描

    /// - Parameters:
    ///   - kinds: 只保留这些类型；默认保护板 + 石栏，避免满屏无关 BLE。
    ///   - timeout: 默认 12 秒（小程序 30 秒过长，过滤后命中更快）。
    func startScan(kinds: Set<DeviceKind>? = nil, timeout: TimeInterval = 12) {
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
        // 不按 UUID 限扫：部分石栏/ANT 广播不含服务 UUID；靠名称过滤即可
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
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
        if central.state == .poweredOn { central.stopScan() }
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
        log("订阅通知 \(notify.uuid.uuidString)")

        let write = activeWriteCharacteristic()
        log("写入特征 \(write?.uuid.uuidString ?? "未找到")")
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

        let type: CBCharacteristicWriteType = useResponse ? .withResponse : .withoutResponse
        let maxLength = max(20, min(512, p.maximumWriteValueLength(for: type) - 3))
        var offset = 0

        while offset < data.count {
            let length = min(maxLength, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            if useResponse {
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
            characteristics[characteristic.uuid.uuidString.uppercased()] = characteristic
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
