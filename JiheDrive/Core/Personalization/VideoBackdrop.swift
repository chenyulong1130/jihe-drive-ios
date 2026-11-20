import AVFoundation
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 相册视频 → 本地临时文件
struct VideoTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("jihe-video-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoTransfer(url: copy)
        }
    }
}

/// 车辆背景视频：存 Documents/Themes，取第一帧当封面兜底
@MainActor
final class VideoBackdropStore: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var poster: UIImage?
    @Published private(set) var importing = false
    @Published var errorText: String?

    /// 单个主题视频上限，避免把免费空间写满
    static let maxBytes: Int64 = 120 * 1024 * 1024

    private let folder: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        folder = base.appendingPathComponent("Themes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        reload()
    }

    var hasVideo: Bool { url != nil }

    private var fileURL: URL { folder.appendingPathComponent("vehicle-backdrop.mp4") }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            url = nil
            poster = nil
            return
        }
        url = fileURL
        loadPoster()
    }

    func save(from source: URL) async throws {
        importing = true
        defer { importing = false }

        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > Self.maxBytes {
            throw BackdropError.tooLarge
        }

        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0.3 else { throw BackdropError.tooShort }

        // 统一转成 mp4，避免 HEVC mov 在部分机型上只剩声音
        let target = folder.appendingPathComponent("vehicle-backdrop.tmp.mp4")
        try? FileManager.default.removeItem(at: target)

        // 优先最高画质；失败再退 1080p；再失败原样拷贝
        let presets = [AVAssetExportPresetHighestQuality, AVAssetExportPreset1920x1080, AVAssetExportPresetPassthrough]
        var exported = false
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: target)
            session.outputURL = target
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            if session.status == .completed {
                exported = true
                break
            }
        }
        if !exported {
            try FileManager.default.copyItem(at: source, to: target)
        }

        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: target, to: fileURL)
        // 大文件不进 iCloud 备份
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = fileURL
        try? mutable.setResourceValues(values)

        url = fileURL
        loadPoster()
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        url = nil
        poster = nil
    }

    private func loadPoster() {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)

        Task { [weak self] in
            let time = CMTime(seconds: 0.2, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { return }
            let image = UIImage(cgImage: result.image)
            guard let self else { return }
            self.poster = image
        }
    }
}

enum BackdropError: LocalizedError {
    case tooLarge
    case tooShort
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "视频超过 120MB，换一个短一点的"
        case .tooShort: return "视频太短，至少要 1 秒"
        case .exportFailed: return "视频转换失败，试试其他格式"
        }
    }
}
