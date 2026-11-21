import AVFoundation
import SwiftUI
import UIKit

/// 无声循环视频。远程地址用 AVPlayer + 播完回零，避开 AVPlayerLooper 对流媒体不稳定。
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var muted: Bool = true
    var fadeBottom: Bool = false

    func makeUIView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView()
        view.fadeBottom = fadeBottom
        view.load(url: url, muted: muted)
        return view
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {
        view.fadeBottom = fadeBottom
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
    private let fadeMask = CAGradientLayer()
    private var player: AVPlayer?
    private var loadedURL: URL?
    private var shouldPlay = true
    private var endObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []
    var fadeBottom = false {
        didSet { applyFade() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(playerLayer)
        applyFade()
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
            self?.resumeIfNeeded()
        })
        appObservers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                self?.player?.pause()
            } else {
                self?.resumeIfNeeded()
            }
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
        fadeMask.frame = bounds
        CATransaction.commit()
        resumeIfNeeded()
    }

    private func applyFade() {
        let canvas = UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1)
        if fadeBottom {
            isOpaque = false
            backgroundColor = .clear
            layer.isOpaque = false
            layer.backgroundColor = UIColor.clear.cgColor
            playerLayer.isOpaque = false
            playerLayer.backgroundColor = UIColor.clear.cgColor
            fadeMask.colors = [
                UIColor.black.cgColor,
                UIColor.black.cgColor,
                UIColor.black.withAlphaComponent(0.35).cgColor,
                UIColor.clear.cgColor
            ]
            fadeMask.locations = [0, 0.78, 0.90, 1]
            layer.mask = fadeMask
        } else {
            isOpaque = true
            backgroundColor = canvas
            layer.isOpaque = true
            layer.backgroundColor = canvas.cgColor
            playerLayer.isOpaque = true
            playerLayer.backgroundColor = canvas.cgColor
            layer.mask = nil
        }
        setNeedsLayout()
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
        // 本地文件限分辨率不会转码，只影响 HLS；远程主题视频按 1080p 封顶
        if !url.isFileURL {
            item.preferredPeakBitRate = 6_000_000
            if #available(iOS 15.0, *) {
                item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
            }
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
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            player?.pause()
            return
        }
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
