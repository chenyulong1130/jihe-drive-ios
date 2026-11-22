import SwiftUI
import AVFoundation
import UIKit

/// CarPlay 画面预览（与 CarWithin 一致的本地显示）：
/// - AVSampleBufferDisplayLayer 渲染解码帧（转码器每解出一帧即可显示）
/// - 触摸直接映射到 CarPlay 显示坐标（1024×480），经 HID 报告回传控制 CarPlay
/// - 支持全屏
struct CPPreviewView: View {
    @ObservedObject var controller: CPMirrorController
    var fullscreen: Bool = false

    var body: some View {
        PreviewUIViewRepresentable(
            transcoder: controller.transcoder,
            onTouches: { controller.touches($0) })
            .clipped()
    }
}

// MARK: - UIKit 渲染与触摸

struct PreviewUIViewRepresentable: UIViewRepresentable {
    let transcoder: CPVideoTranscoder
    let onTouches: ([(id: Int, x: Double, y: Double, down: Bool)]) -> Void

    func makeUIView(context: Context) -> CPPreviewUIView {
        let view = CPPreviewUIView()
        view.transcoder = transcoder
        view.onTouches = onTouches
        return view
    }

    func updateUIView(_ view: CPPreviewUIView, context: Context) {
        view.onTouches = onTouches
    }
}

/// 渲染层：CADisplayLink 轮询最新解码帧 → AVSampleBufferDisplayLayer。
final class CPPreviewUIView: UIView {

    var transcoder: CPVideoTranscoder? {
        didSet { startDisplayLink() }
    }

    /// 触摸回调：归一化 0…1 坐标 + 按下/移动/抬起。
    var onTouches: (([(id: Int, x: Double, y: Double, down: Bool)]) -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
    private var displayLink: CADisplayLink?
    private var lastFrame: Int = -1

    override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    override init(frame: CGRect) {
        self.onTouches = { _ in }
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        self.onTouches = { _ in }
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderLatest))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    deinit {
        displayLink?.invalidate()
    }

    @objc private func renderLatest() {
        guard let transcoder else { return }
        guard let snapshot = transcoder.snapshotForDisplay() else { return }
        guard snapshot.frame != lastFrame else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: snapshot.buffer,
            formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime,
                                          preferredTimescale: 1_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: snapshot.buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else { return }
        displayLayer.enqueue(sampleBuffer)
        lastFrame = snapshot.frame
    }

    // MARK: - 触摸 → CarPlay 坐标

    /// 画面在视图内的等比区域（1024×480 aspect-fit）。
    private func videoRect() -> CGRect {
        let boundsSize = bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return .zero }
        let ratio = CGFloat(1024.0 / 480.0)
        var width = boundsSize.width
        var height = width / ratio
        if height > boundsSize.height {
            height = boundsSize.height
            width = height * ratio
        }
        return CGRect(x: (boundsSize.width - width) / 2,
                      y: (boundsSize.height - height) / 2,
                      width: width, height: height)
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(touches, down: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(touches, down: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(touches, down: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(touches, down: false)
    }
}
