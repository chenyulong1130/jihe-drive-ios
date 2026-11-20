import AVFoundation
import SwiftUI
import UIKit

/// 无声循环播放的视频层，用作车辆主视觉背景。
/// 挂到窗口后自动播放，进入后台暂停、回到前台续播，不打断正在播放的音乐。
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var muted: Bool = true

    func makeUIView(context: Context) -> VideoPlayerUIView {
        let view = VideoPlayerUIView(frame: .zero)
        view.configure(url: url, muted: muted)
        return view
    }

    func updateUIView(_ view: VideoPlayerUIView, context: Context) {
        view.configure(url: url, muted: muted)
    }

    static func dismantleUIView(_ view: VideoPlayerUIView, coordinator: ()) {
        view.teardown()
    }
}

final class VideoPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var pausedBySystem = false

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer?.videoGravity = .resizeAspectFill

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(url: URL, muted: Bool) {
        player?.isMuted = muted

        guard loadedURL != url else {
            if !pausedBySystem { player?.play() }
            return
        }

        teardown()
        loadedURL = url

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = muted
        queue.actionAtItemEnd = .advance
        queue.preventsDisplaySleepDuringVideoPlayback = false

        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer?.player = queue
        player = queue

        if !pausedBySystem { queue.play() }
    }

    func teardown() {
        player?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        looper = nil
        player = nil
        loadedURL = nil
    }

    @objc private func handleBackground() {
        pausedBySystem = true
        player?.pause()
    }

    @objc private func handleForeground() {
        pausedBySystem = false
        player?.play()
    }
}
