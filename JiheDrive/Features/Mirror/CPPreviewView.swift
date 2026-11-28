import SwiftUI
import AVFoundation
import UIKit

// MARK: - 视频帧广播（接收线程 → 主线程显示层）

enum CPVideoFrameEvent {
    case frame(Data, CPVideoCodec)
    case reset
}

/// 多个预览（卡片/全屏）订阅同一路原始 H.264/H.265 访问单元。
/// 直接送 AVSampleBufferDisplayLayer 解码，绕开转码器自解码，避免转码器失效时预览黑屏。
final class CPVideoFrameHub {
    private let lock = NSLock()
    private var sinks: [UUID: (CPVideoFrameEvent) -> Void] = [:]

    @discardableResult
    func subscribe(_ sink: @escaping (CPVideoFrameEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        sinks[id] = sink
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        sinks.removeValue(forKey: id)
        lock.unlock()
    }

    func publish(_ event: CPVideoFrameEvent) {
        lock.lock()
        let current = Array(sinks.values)
        lock.unlock()
        guard !current.isEmpty else { return }
        // 接收线程直接分发：每个 sink 各自跳自己的解码队列。
        // 不再绕主线程——帧事件（25~30fps）不该碰主线程，全屏+卡片
        // 同时订阅时主线程被轰炸正是「一点全屏就卡住」的根因
        for sink in current { sink(event) }
    }
}

// MARK: - SwiftUI 包装

struct CPPreviewView: View {
    @ObservedObject var controller: CPMirrorController
    var fullscreen: Bool = false
    /// true 时取消订阅（全屏呈现期间卡片预览停喂数据，同一帧不再双路解码）
    var paused: Bool = false
    /// false = 纯展示（不向 CarPlay 回传触摸，点击走 onTap）；
    /// 卡片预览传 false，全屏操作面传 true
    var interactive: Bool = true
    /// true = 画面铺满容器（等比放大裁切溢出），触控按裁切后可视区换算；
    /// false = 等比缩放留黑边（aspect fit）
    var fillsScreen: Bool = false
    /// 单击手势（UIKit 识别器实现，不经 SwiftUI 手势层——手势层会让触控下发变涩）
    var onTap: (() -> Void)? = nil

    var body: some View {
        PreviewUIViewRepresentable(
            hub: controller.frameHub,
            paused: paused,
            onTap: onTap,
            onTouches: interactive ? { controller.touches($0) } : { _ in },
            onKeyframeNeeded: { controller.requestKeyFrame() },
            fillsScreen: fillsScreen)
            .clipped()
    }
}

struct PreviewUIViewRepresentable: UIViewRepresentable {
    let hub: CPVideoFrameHub
    var paused: Bool = false
    var onTap: (() -> Void)? = nil
    let onTouches: ([(id: Int, x: Double, y: Double, down: Bool)]) -> Void
    let onKeyframeNeeded: () -> Void
    var fillsScreen: Bool = false

    func makeUIView(context: Context) -> CPDisplaySurface {
        let view = CPDisplaySurface()
        view.onTouches = onTouches
        view.onKeyframeNeeded = onKeyframeNeeded
        view.onTap = onTap
        view.fillsScreen = fillsScreen
        context.coordinator.hub = hub
        context.coordinator.paused = paused
        if !paused {
            // 解析/建缓冲移出主线程：AnnexB 解析 + CMBlockBuffer 拷贝每帧都要做，
            // 全在主线程跑会让滑动/动画发涩；层操作统一走专用串行队列
            context.coordinator.subscribe(to: hub, view: view)
        }
        return view
    }

    func updateUIView(_ view: CPDisplaySurface, context: Context) {
        view.onTouches = onTouches
        view.onKeyframeNeeded = onKeyframeNeeded
        view.onTap = onTap
        view.fillsScreen = fillsScreen
        if paused != context.coordinator.paused {
            context.coordinator.paused = paused
            // reset 一律排进解码队列：状态/层只在该队列访问，主线程不动
            view.decodeQueue.async { view.reset() }
            if paused {
                // 全屏期间卡片停喂数据：防双路解码，也防后台攒帧
                context.coordinator.unsubscribe()
            } else {
                context.coordinator.subscribe(to: hub, view: view)
            }
        }
    }

    static func dismantleUIView(_ view: CPDisplaySurface, coordinator: Coordinator) {
        coordinator.unsubscribe()
        coordinator.hub = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hub: CPVideoFrameHub?
        var token: UUID?
        var paused = false
        /// 帧解析/解码队列（与层交互全部在此队列，主线程只管触摸）
        let decodeQueue = DispatchQueue(label: "cp.preview.decode")

        func subscribe(to hub: CPVideoFrameHub, view: CPDisplaySurface) {
            guard token == nil else { return }
            token = hub.subscribe { [weak view] event in
                guard let view else { return }
                view.decodeQueue.async {
                    switch event {
                    case .frame(let data, let codec):
                        do { try view.enqueue(accessUnit: data, codec: codec) }
                        catch { view.onDecodeError?(error.localizedDescription) }
                    case .reset:
                        view.reset()
                    }
                }
            }
            // 兜底偶发黑屏：订阅后 0.8 秒仍没出过画面，主动再要一次关键帧
            // （覆盖关键帧请求被吞、显示层未就绪等单次恢复失败的场景）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak view] in
                guard let self, self.token != nil, let view, !view.hasDisplayedFrame else { return }
                view.onKeyframeNeeded?()
            }
        }

        func unsubscribe() {
            hub?.unsubscribe(token)
            token = nil
        }
    }
}

// MARK: - 参数集管理（H.264 / H.265）

private struct CPParameterSets {
    var codec: CPVideoCodec
    var vps: Data?
    var sps: Data?
    var pps: Data?

    var isComplete: Bool {
        sps != nil && pps != nil && (codec == .h264 || vps != nil)
    }

    var ordered: [Data] {
        (codec == .h265 ? [vps, sps, pps] : [sps, pps]).compactMap { $0 }
    }

    @discardableResult
    mutating func absorb(_ unit: Data) -> Bool {
        switch codec.parameterSet(unit) {
        case .vps?: if vps != unit { vps = unit; return true }
        case .sps?: if sps != unit { sps = unit; return true }
        case .pps?: if pps != unit { pps = unit; return true }
        case nil: break
        }
        return false
    }
}

// MARK: - 显示层（解码恢复闭环）

final class CPDisplaySurface: UIView {
    override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    var onTouches: (([(id: Int, x: Double, y: Double, down: Bool)]) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    var onDecodeError: ((String) -> Void)?
    var onTap: (() -> Void)?
    /// true = 画面铺满容器（裁切溢出），显示层与触控换算都按 aspect fill；
    /// false = 等比缩放留黑边（默认）
    var fillsScreen: Bool = false {
        didSet {
            guard fillsScreen != oldValue else { return }
            displayLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        }
    }
    /// 帧解析/解码队列（层与状态只在此队列访问，主线程只管触摸）
    let decodeQueue = DispatchQueue(label: "cp.preview.decode")

    private var format: CMVideoFormatDescription?
    private var parameters: CPParameterSets?
    private var pending: [(buffer: CMSampleBuffer, bytes: Int)] = []
    private var pendingBytes = 0
    private var requesting = false
    private var awaitingKeyframe = false
    private var lastRecovery: TimeInterval = -.infinity
    private var checkingDisplaySince: TimeInterval?
    /// 本轮订阅后是否成功送出过画面（订阅后 0.8s 无画面就再要关键帧的判据）
    private(set) var hasDisplayedFrame = false
    private var needsRecovery: Bool {
        displayLayer.requiresFlushToResumeDecoding || displayLayer.status == .failed
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isMultipleTouchEnabled = true
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        // 单击走 UIKit 识别器（不经 SwiftUI 手势层，触控下发不延迟）；
        // 不取消触摸：CarPlay 侧照常收到完整的按下/抬起
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        // 拖动救援手势：卡片在 SwiftUI ScrollView 里，垂直拖动会被页面滚动
        // 拦截并 touchesCancelled——同手势与滚动并行识别，拖动继续转发 CarPlay
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(
            self, selector: #selector(decodeFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: displayLayer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recoveryFlagChanged),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: displayLayer)
    }

    /// 与页面滚动手势并行识别：卡片拖动不再被滚动吃掉
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onTap?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLayer.stopRequestingMediaData()
    }

    @objc private func decodeFailed(_ note: Notification) {
        decodeQueue.async { [weak self] in
            guard let self, self.format != nil, self.needsRecovery,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            self.recover(reason: "本机显示层解码失败")
        }
    }

    @objc private func recoveryFlagChanged() {
        decodeQueue.async { [weak self] in
            guard let self, self.format != nil, self.displayLayer.requiresFlushToResumeDecoding,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            self.recover(reason: "系统要求刷新视频解码")
        }
    }

    private func recover(reason: String) {
        displayLayer.stopRequestingMediaData()
        requesting = false
        pending.removeAll()
        pendingBytes = 0
        displayLayer.flush()
        checkingDisplaySince = nil
        lastRecovery = ProcessInfo.processInfo.systemUptime
        awaitingKeyframe = true
        onDecodeError?(reason)
        onKeyframeNeeded?()
    }

    func reset() {
        displayLayer.stopRequestingMediaData()
        requesting = false
        pending.removeAll()
        pendingBytes = 0
        awaitingKeyframe = false
        checkingDisplaySince = nil
        lastRecovery = -.infinity
        hasDisplayedFrame = false
        displayLayer.flushAndRemoveImage()
        format = nil
        parameters = nil
    }

    private func makeFormat(_ sets: CPParameterSets) throws -> CMVideoFormatDescription {
        let units = sets.ordered.map { $0 as NSData }
        let pointers = units.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = units.map(\.length)
        var description: CMVideoFormatDescription?
        let status: OSStatus
        switch sets.codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &description)
        }
        guard status == noErr, let description else {
            throw CPError.malformed("\(sets.codec.displayName) 参数集无效（\(status)）")
        }
        return description
    }

    func enqueue(accessUnit: Data, codec: CPVideoCodec) throws {
        let units = try CPAnnexB.units(in: accessUnit)
        if parameters?.codec != codec {
            parameters = CPParameterSets(codec: codec)
            format = nil
        }
        var picture: [Data] = []
        var changed = false
        for unit in units {
            if parameters?.absorb(unit) == true { changed = true; continue }
            // 参数集 NAL（含与缓存相同的重复包）一律不进画面数据——
            // 与参考实现保持一致，避免重复 SPS/PPS 混入解码队列。
            if codec.parameterSet(unit) != nil { continue }
            picture.append(unit)
        }
        if (changed || format == nil), let sets = parameters, sets.isComplete {
            let newFormat = try makeFormat(sets)
            displayLayer.stopRequestingMediaData()
            requesting = false
            pending.removeAll()
            pendingBytes = 0
            displayLayer.flush()
            format = newFormat
            awaitingKeyframe = false
        }
        guard !picture.isEmpty else { return }
        guard let format else {
            if !awaitingKeyframe {
                awaitingKeyframe = true
                onKeyframeNeeded?()
            }
            return
        }

        let keyframe = picture.contains { codec.isRandomAccess($0) }
        let now = ProcessInfo.processInfo.systemUptime
        if needsRecovery {
            guard now - lastRecovery >= 0.5 else { return }
            recover(reason: "显示层需要恢复")
            guard !needsRecovery else { return }
        } else if pending.count >= 30 || pendingBytes > 16 * 1024 * 1024 {
            recover(reason: "显示积压 \(pending.count) 帧")
        } else if #available(iOS 17.4, *) {
            if displayLayer.isReadyForDisplay {
                checkingDisplaySince = nil
            } else if !pending.isEmpty || requesting {
                let started = checkingDisplaySince ?? now
                checkingDisplaySince = started
                if now - started >= 1.5, now - lastRecovery >= 1.5 {
                    recover(reason: "收到视频帧后显示层未就绪")
                }
            }
        }
        if awaitingKeyframe {
            guard keyframe else { return }
            awaitingKeyframe = false
        }

        let bytes = CPAnnexB.lengthPrefixed(picture)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { return }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { return }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        pending.append((sample, bytes.count))
        pendingBytes += bytes.count
        hasDisplayedFrame = true
        if !requesting {
            requesting = true
            displayLayer.requestMediaDataWhenReady(on: decodeQueue) { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while displayLayer.isReadyForMoreMediaData, !pending.isEmpty {
            let item = pending.removeFirst()
            pendingBytes -= item.bytes
            displayLayer.enqueue(item.buffer)
        }
        if pending.isEmpty {
            displayLayer.stopRequestingMediaData()
            requesting = false
        }
    }

    // MARK: - 触摸 → CarPlay 坐标（合并上报）

    private struct TouchState {
        var x: Double
        var y: Double
        var down: Bool
    }

    /// 全量触控状态：移动按 60Hz 合并，按下/抬起立即上报，
    /// 避免 move 事件逐条 RTSP 命令洪泛拖慢车机 HID 处理
    private var contacts: [Int: TouchState] = [:]
    /// 车端已知触点状态：只上报有变化的整帧，静止时不再 60Hz 重发
    private var lastSent: [Int: TouchState] = [:]
    private var touchTimer: Timer?
    /// 上报限速 ≤60Hz：移动事件可能 120Hz 到达，洪泛会拖慢车机 HID
    private var lastSendUptime: TimeInterval = 0
    private var flushScheduled = false

    private func videoRect() -> CGRect {
        let boundsSize = bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return .zero }
        var ratio = CGFloat(1024.0 / 480.0)
        if let format {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            if size.width > 0, size.height > 0 {
                ratio = CGFloat(size.width) / CGFloat(size.height)
            }
        }
        // fillsScreen = aspect fill（画面铺满、裁切溢出）；默认 aspect fit（留黑边）
        let viewRatio = boundsSize.width / boundsSize.height
        if fillsScreen, viewRatio > 0, viewRatio != ratio {
            if viewRatio > ratio {
                // 容器更宽：铺满宽度，高度溢出上下裁切
                let width = boundsSize.width
                let height = width / ratio
                return CGRect(x: 0, y: (boundsSize.height - height) / 2, width: width, height: height)
            } else {
                // 容器更高：铺满高度，宽度溢出左右裁切
                let height = boundsSize.height
                let width = height * ratio
                return CGRect(x: (boundsSize.width - width) / 2, y: 0, width: width, height: height)
            }
        }
        return AVMakeRect(aspectRatio: CGSize(width: ratio, height: 1), insideRect: bounds)
    }

    private func normalizedPoint(_ touch: UITouch) -> (x: Double, y: Double)? {
        let rect = videoRect()
        guard rect.width > 0, rect.height > 0, rect.contains(touch.location(in: self)) else { return nil }
        let location = touch.location(in: self)
        let x = Double((location.x - rect.minX) / rect.width)
        let y = Double((location.y - rect.minY) / rect.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func touchKey(_ touch: UITouch) -> Int { (touch as NSObject).hash }

    private func update(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let normalized = normalizedPoint(touch) else { continue }
            contacts[touchKey(touch)] = TouchState(x: normalized.x, y: normalized.y, down: true)
        }
        startTouchTimerIfNeeded()
    }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            let key = touchKey(touch)
            guard contacts[key] != nil else { continue }
            if let normalized = normalizedPoint(touch) {
                contacts[key]?.x = normalized.x
                contacts[key]?.y = normalized.y
            }
            contacts[key]?.down = false
        }
        flushContacts()
    }

    private func flushContacts() {
        guard !contacts.isEmpty else { return }
        // HID 是全量状态帧：任一触点变化才上报（不能按槽去重，否则未变化槽会被判抬起）
        var changed = contacts.count != lastSent.count
        if !changed {
            for (key, state) in contacts {
                guard let sent = lastSent[key],
                      sent.down == state.down, sent.x == state.x, sent.y == state.y else {
                    changed = true
                    break
                }
            }
        }
        guard changed else {
            contacts = contacts.filter { $0.value.down }
            if contacts.isEmpty {
                touchTimer?.invalidate()
                touchTimer = nil
            }
            return
        }
        // 上报限速 ≤60Hz：移动事件可能 120Hz 到达，洪泛会拖慢车机 HID；
        // 限速窗口内到达的移动合并，到点后只发最新状态
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSendUptime < 0.015 {
            schedulePendingFlush()
            return
        }
        lastSendUptime = now
        let list = contacts.map { entry in
            (id: entry.key, x: entry.value.x, y: entry.value.y, down: entry.value.down)
        }
        for (key, state) in contacts where state.down {
            lastSent[key] = state
        }
        for key in lastSent.keys where contacts[key] == nil {
            lastSent.removeValue(forKey: key)
        }
        onTouches?(list)
        // 抬起的槽上报后移除；没有活动触点就停掉定时器
        contacts = contacts.filter { $0.value.down }
        if contacts.isEmpty {
            touchTimer?.invalidate()
            touchTimer = nil
        }
    }

    private func schedulePendingFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.flushScheduled = false
            self?.flushContacts()
        }
    }

    private func startTouchTimerIfNeeded() {
        guard touchTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.flushContacts()
        }
        RunLoop.main.add(timer, forMode: .common)
        touchTimer = timer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(touches)
        flushContacts()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // pan 接管指针期间原始移动不上报（同一手指不占双槽）
        guard !panOwnsPointer else { return }
        update(touches)
        // 移动立即上报（带变化去重）：不等 16ms 定时器节拍，少半帧指针延迟
        flushContacts()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !panOwnsPointer else { return }
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !panOwnsPointer else { return }
        lift(touches)
    }

    // MARK: - 拖动救援（页面滚动拦截 touchesCancelled 时由 Pan 手势续传）
    //
    // Pan 手势与页面滚动并行识别；激活后指针归属权交给 pan（固定 key），
    // 原始 touches 路径暂停，避免同一根手指占两个 HID 槽。

    /// pan 接管的指针 key（与 UITouch.hash 域不冲突的常量）
    private static let panPointerKey = 1_000_001
    /// pan 正在驱动指针：raw touches 的 move/end 不再上报
    private var panOwnsPointer = false

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let rect = videoRect()
        let key = Self.panPointerKey
        switch gesture.state {
        case .began:
            // 归属权交接：抬起当前所有原始触点，改由 pan 指针接管
            panOwnsPointer = true
            let held = contacts.keys
            liftKeys(held)
            guard rect.contains(location) else { return }
            let x = Double((location.x - rect.minX) / rect.width)
            let y = Double((location.y - rect.minY) / rect.height)
            contacts[key] = TouchState(x: min(max(x, 0), 1), y: min(max(y, 0), 1), down: true)
            startTouchTimerIfNeeded()
            flushContacts()
        case .changed:
            guard panOwnsPointer, rect.contains(location) else { return }
            let x = Double((location.x - rect.minX) / rect.width)
            let y = Double((location.y - rect.minY) / rect.height)
            contacts[key] = TouchState(x: min(max(x, 0), 1), y: min(max(y, 0), 1), down: true)
            flushContacts()
        case .ended, .cancelled, .failed:
            guard panOwnsPointer else { return }
            panOwnsPointer = false
            contacts[key]?.down = false
            flushContacts()
        default:
            break
        }
    }

    /// 按 key 抬起触点（pan 接管时释放原始触点占用）
    private func liftKeys(_ keys: [Int]) {
        for key in keys {
            contacts[key]?.down = false
        }
        flushContacts()
    }
}

extension CPDisplaySurface: UIGestureRecognizerDelegate {
    /// 允许与页面滚动并行识别；也允许与自己的 tap 识别器并行
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
