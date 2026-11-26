import Foundation

@MainActor
final class MotorStore: ObservableObject {
    @Published private(set) var params = MotorParams()
    @Published private(set) var paramsLoaded = false
    @Published private(set) var busy = false
    @Published private(set) var status = "等待读取参数"
    @Published private(set) var logs: [String] = []

    @Published var targetPercent: Double = 0
    @Published var speedLevel: Double = 0
    @Published var rangeMin: Double = 0
    @Published var rangeMax: Double = 100
    @Published var selfMode = false
    @Published var reverse = false
    @Published var workingMode = 0
    @Published var selectedProject = 0
    @Published var lightSwitch = false

    private let decoder = MotorFrameDecoder()
    private weak var ble: DeviceBLEManager?
    private var retryCount = 0
    private var timeoutTask: Task<Void, Never>?

    /// 不同页面各用独立的 handlerKey，避免两个 MotorStore 实例互相覆盖通知回调
    private var handlerKey = "motor"

    func attach(_ ble: DeviceBLEManager, handlerKey: String = "motor") {
        self.ble = ble
        self.handlerKey = handlerKey
        ble.registerDataHandler(handlerKey) { [weak self] data in
            Task { @MainActor in self?.feed(data) }
        }
    }

    func deactivate() {
        ble?.unregisterDataHandler(handlerKey)
        timeoutTask?.cancel()
        timeoutTask = nil
        busy = false
    }

    func loadParams() {
        retryCount = 0
        paramsLoaded = false
        status = "电机参数加载中"
        requestParams()
    }

    private func requestParams() {
        Task {
            await send([4, 2, 15], timeout: 1.0)
            scheduleTimeout(seconds: 1.0) { [weak self] in
                guard let self else { return }
                if self.retryCount < 2 {
                    self.retryCount += 1
                    self.requestParams()
                } else {
                    self.status = "读取参数失败，请重连"
                    self.retryCount = 0
                }
            }
        }
    }

    private func send(_ command: [UInt8], timeout: Double = 2.0) async {
        guard let ble, ble.isConnected else {
            status = "请先连接设备"
            return
        }
        busy = true
        let frame = MotorProtocol.frame(command)
        appendLog("发送 \(frame.hexString)")
        do {
            try await ble.write(frame)
            if timeout != 1.0 {
                scheduleTimeout(seconds: timeout) { [weak self] in
                    guard let self else { return }
                    if self.busy {
                        self.busy = false
                        self.status = "指令无应答"
                    }
                }
            }
        } catch {
            busy = false
            status = "发送失败：\(error.localizedDescription)"
        }
    }

    private func scheduleTimeout(seconds: Double, action: @escaping () -> Void) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            action()
        }
    }

    private func feed(_ data: Data) {
        for frame in decoder.feed(data) {
            guard let event = MotorProtocol.parse(frame) else {
                appendLog("忽略帧：\(Data(frame).hexString)")
                continue
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            busy = false
            switch event {
            case .ack:
                status = "指令已执行"
            case .invalid:
                status = "电机控制错误：指令无效"
            case .moved(let absolute, let target):
                params.absolutePercent = absolute
                params.targetPercent = target
                status = "移动完成 · \(absolute)%"
            case .busy:
                status = "电机繁忙中"
            case .selfTestStart:
                status = "自检开始"
            case .selfTestDone(let absolute, let target):
                params.absolutePercent = absolute
                params.targetPercent = target
                status = "自检完成 · \(absolute)%"
            case .homingDone(let absolute, let target):
                params.absolutePercent = absolute
                params.targetPercent = target
                status = "归位完成 · \(absolute)%"
            case .params(let received):
                apply(received)
                paramsLoaded = true
                retryCount = 0
                status = "参数已读取"
            case .unknown(let code):
                status = "未知命令 \(code)"
            }
        }
    }

    private func apply(_ received: MotorParams) {
        params = received
        rangeMin = Double(received.minPercent)
        rangeMax = Double(received.maxPercent)
        targetPercent = Double(received.targetPercent)
        speedLevel = Double(received.speedLevel)
        selfMode = received.selfMode
        reverse = received.reverse
        workingMode = received.workingMode
        selectedProject = received.project
    }

    // MARK: - 控制指令

    func moveTo(percent: Double) {
        let value = min(100, max(0, percent))
        let flag = reverse ? 1 : 0
        let logical = reverse ? 100 - value : value
        let span = Double(max(0, params.maxPercent - params.minPercent))
        let absolute = Int(round(Double(params.minPercent) + span * logical / 100.0))
        Task { await send([7, 2, 1, min(100, max(0, absolute)), Int(value), flag]) }
    }

    func setSpeed(_ level: Double) {
        Task { await send([5, 2, 2, min(10, max(0, Int(level)))]) }
    }

    func setSelfTest(enabled: Bool) {
        Task { await send([7, 2, 3, enabled ? 1 : 0, workingMode, params.selfModeDir]) }
    }

    func softZero() {
        Task { await send([4, 2, 4]) }
    }

    func hardZero() {
        Task { await send([5, 2, 5, params.homingDir]) }
    }

    func setReverse(_ enabled: Bool) {
        Task { await send([5, 2, 6, enabled ? 1 : 0]) }
    }

    func setRange() {
        let minValue = Int(rangeMin), maxValue = Int(rangeMax)
        guard minValue >= 0, maxValue <= 100, minValue < maxValue else {
            status = "限位无效：需满足 0 ≤ 下限 < 上限 ≤ 100"
            return
        }
        Task { await send([6, 2, 7, minValue, maxValue]) }
    }

    func setWorkingMode(_ mode: Int) {
        guard mode == 0 || mode == 1 else { return }
        workingMode = mode
        Task { await send([5, 2, 7, mode]) }
    }

    func applyProject(_ project: MotorProject) {
        selectedProject = project.index
        rangeMin = Double(project.min)
        rangeMax = Double(project.max)
        reverse = project.isReverse
        workingMode = 0
        selfMode = true
        let command: [UInt8] = [
            13, 2, 8,
            UInt8(project.index),
            UInt8(project.direction),
            UInt8(project.min),
            UInt8(project.max),
            0,
            UInt8(project.reverseFlag),
            0,
            1,
            project.isReverse ? 1 : 0
        ]
        Task { await send(command) }
    }

    private func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 40 { logs.removeFirst(logs.count - 40) }
    }
}
