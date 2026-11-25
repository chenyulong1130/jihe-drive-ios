import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

/// 系统画中画悬浮窗：CarPlay 实时画面挂到 AVSampleBufferDisplayLayer，
/// 经 AVPictureInPictureController 变成系统悬浮窗——可拖动、可缩放、
/// 悬浮在任意 App 之上，离开 App / 锁屏都能继续。
/// 注意：画中画是系统窗口，只能观看，无法在其中触控（系统限制）。
final class CPVideoSurface: NSObject {
    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var lastFrame = -1

    var hasPicture: Bool { lastFrame >= 0 }

    func enqueue(pixelBuffer: CVPixelBuffer, frame: Int) {
        guard frame != lastFrame else { return }
        lastFrame = frame
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime,
                                          preferredTimescale: 1_000),
            decodeTimeStamp: .invalid)
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sample = sampleBuffer else { return }
        displayLayer.enqueue(sample)
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
    }

    func reset() {
        lastFrame = -1
        displayLayer.flush()
    }
}

/// 画中画控制器 + 喂帧循环。必须在用户手势调用栈里调用 start()。
final class CPPictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    let surface = CPVideoSurface()
    private var controller: AVPictureInPictureController?
    private var displayLink: CADisplayLink?
    private(set) var isActive = false

    var onLog: ((String) -> Void)?
    var onStopped: (() -> Void)?
    /// 帧来源（主线程 display link 调用）：返回最新解码帧与递增帧号。
    var frameProvider: (() -> (buffer: CVPixelBuffer, frame: Int)?)?

    override init() {
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onLog?("此系统不支持画中画")
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: surface.displayLayer,
            playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
    }

    /// 有解码画面后开始持续喂数（画中画就绪的前提）。
    func startFeed() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopFeed() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let snapshot = frameProvider?() else { return }
        surface.enqueue(pixelBuffer: snapshot.buffer, frame: snapshot.frame)
    }

    /// 启动画中画悬浮窗。返回 false 表示当前还不能启动（画面未就绪）。
    func start() -> Bool {
        guard let controller else { return false }
        prepareAudioSession()
        guard controller.isPictureInPicturePossible else { return false }
        controller.startPictureInPicture()
        return true
    }

    func stop() {
        controller?.stopPictureInPicture()
        stopFeed()
        surface.reset()
    }

    /// 无声也要有播放类音频会话，画中画才能在离开 App 后保持。
    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        // 只读实时流，没有播放/暂停语义
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

extension CPPictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        onStopped?()
    }
}
