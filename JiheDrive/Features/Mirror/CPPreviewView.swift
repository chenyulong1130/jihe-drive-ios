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
        DispatchQueue.main.async {
            for sink in current { sink(event) }
        }
    }
}

// MARK: - SwiftUI 包装

struct CPPreviewView: View {
    @ObservedObject var controller: CPMirrorController
    var fullscreen: Bool = false

    var body: some View {
        PreviewUIViewRepresentable(
            hub: controller.frameHub,
            onTouches: { controller.touches($0) },
            onKeyframeNeeded: { controller.requestKeyFrame() })
            .clipped()
    }
}

struct PreviewUIViewRepresentable: UIViewRepresentable {
    let hub: CPVideoFrameHub
    let onTouches: ([(id: Int, x: Double, y: Double, down: Bool)]) -> Void
    let onKeyframeNeeded: () -> Void

    func makeUIView(context: Context) -> CPDisplaySurface {
        let view = CPDisplaySurface()
        view.onTouches = onTouches
        view.onKeyframeNeeded = onKeyframeNeeded
        context.coordinator.hub = hub
        context.coordinator.token = hub.subscribe { [weak view] event in
            guard let view else { return }
            switch event {
            case .frame(let data, let codec):
                do { try view.enqueue(accessUnit: data, codec: codec) }
                catch { view.onDecodeError?(error.localizedDescription) }
            case .reset:
                view.reset()
            }
        }
        return view
    }

    func updateUIView(_ view: CPDisplaySurface, context: Context) {
        view.onTouches = onTouches
        view.onKeyframeNeeded = onKeyframeNeeded
    }

    static func dismantleUIView(_ view: CPDisplaySurface, coordinator: Coordinator) {
        coordinator.hub?.unsubscribe(coordinator.token)
        coordinator.token = nil
        coordinator.hub = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hub: CPVideoFrameHub?
        var token: UUID?
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

    private var format: CMVideoFormatDescription?
    private var parameters: CPParameterSets?
    private var pending: [(buffer: CMSampleBuffer, bytes: Int)] = []
    private var pendingBytes = 0
    private var requesting = false
    private var awaitingKeyframe = false
    private var lastRecovery: TimeInterval = -.infinity
    private var checkingDisplaySince: TimeInterval?
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(decodeFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: displayLayer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recoveryFlagChanged),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: displayLayer)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLayer.stopRequestingMediaData()
    }

    @objc private func decodeFailed(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.format != nil, self.needsRecovery,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            self.recover(reason: "本机显示层解码失败")
        }
    }

    @objc private func recoveryFlagChanged() {
        DispatchQueue.main.async { [weak self] in
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
            if parameters?.absorb(unit) == true { changed = true }
            else { picture.append(unit) }
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
        if !requesting {
            requesting = true
            displayLayer.requestMediaDataWhenReady(on: .main) { [weak self] in self?.drain() }
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

    // MARK: - 触摸 → CarPlay 坐标

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

    private func report(_ touches: Set<UITouch>, down: Bool) {
        var points: [(id: Int, x: Double, y: Double, down: Bool)] = []
        for touch in touches {
            guard let normalized = normalizedPoint(touch) else { continue }
            points.append((id: (touch as NSObject).hash, x: normalized.x, y: normalized.y, down: down))
        }
        guard !points.isEmpty else { return }
        onTouches?(points)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, down: false) }
}
