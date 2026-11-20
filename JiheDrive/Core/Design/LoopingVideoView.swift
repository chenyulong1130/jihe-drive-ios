import AVFoundation
import SwiftUI
import UIKit

/// 无声循环视频。远程地址用 AVPlayer + 播完回零，避开 AVPlayerLooper 对流媒体不稳定。
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LoopingPlayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: proposal.height ?? uiView.bounds.height)
    }

    static func dismantleUIView(_ view: LoopingPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingPlayerView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var loadedURL: URL?
    private var shouldPlay = true
    private var endObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1)
        isOpaque = true
        isUserInteractionEnabled = false
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1).cgColor
        layer.addSublayer(playerLayer)
        Self.activateAudio()

        let center = NotificationCenter.default
        appObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shouldPlay = false
            self?.player?.pause()
        })
        appObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shouldPlay = true
            self?.player?.play()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
        if window != nil { resumeIfNeeded() }
    }

    func load(url: URL, muted: Bool) {
        player?.isMuted = muted
        if loadedURL == url {
            resumeIfNeeded()
            return
        }
        stop()
        loadedURL = url
        Self.activateAudio()

        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 0
        if #available(iOS 15.0, *) {
            item.preferredMaximumResolution = .zero
        }
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.volume = 0
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        playerLayer.player = player

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        resumeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard shouldPlay, bounds.width > 1, bounds.height > 1 else { return }
        player?.play()
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        playerLayer.player = nil
        player = nil
        loadedURL = nil
    }

    private static func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }
}
