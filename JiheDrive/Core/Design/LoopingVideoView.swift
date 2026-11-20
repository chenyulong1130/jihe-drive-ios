import AVFoundation
import SwiftUI
import UIKit

/// 无声循环视频层。用普通 UIView 承载 AVPlayerLayer 子层，
/// 在 layoutSubviews 里同步 frame，避免 SwiftUI 布局时机不同步导致黑屏。
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var muted: Bool = true

    func makeUIView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView()
        view.load(url: url, muted: muted)
        return view
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {
        view.load(url: url, muted: muted)
    }

    /// 视频层按父视图给的大小铺满，绝不反过来撑大布局
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LoopingPlayerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: LoopingPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingPlayerView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var queue: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var shouldPlay = true
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.clear.cgColor
        layer.addSublayer(playerLayer)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shouldPlay = false
            self?.queue?.pause()
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.shouldPlay = true
            self.queue?.play()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        resumeIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            resumeIfNeeded()
        }
    }

    func load(url: URL, muted: Bool) {
        queue?.isMuted = muted
        guard loadedURL != url else {
            resumeIfNeeded()
            return
        }
        stop()
        loadedURL = url

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // 不限峰值码率，避免主题视频被压糊
        item.preferredPeakBitRate = 0
        if #available(iOS 15.0, *) {
            item.preferredMaximumResolution = .zero
        }
        let player = AVQueuePlayer()
        player.isMuted = muted
        player.volume = 0
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        player.preventsDisplaySleepDuringVideoPlayback = false

        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        queue = player
        resumeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard shouldPlay else { return }
        if queue?.timeControlStatus != .playing {
            queue?.play()
        }
    }

    func stop() {
        queue?.pause()
        looper?.disableLooping()
        playerLayer.player = nil
        looper = nil
        queue = nil
        loadedURL = nil
    }
}
