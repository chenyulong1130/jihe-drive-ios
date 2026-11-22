import Foundation
import UIKit
import SwiftUI

/// 远程资源落盘：模型 / 主题视频 / 车图 / 仪表轮廓，避免每次打开都重新下载。
enum ResourceCache {
    private static let memory = NSCache<NSString, UIImage>()

    static func bootstrap() {
        memory.countLimit = 80
        memory.totalCostLimit = 48 * 1024 * 1024
        let http = directory.appendingPathComponent("http", isDirectory: true)
        try? FileManager.default.createDirectory(at: http, withIntermediateDirectories: true)
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 400 * 1024 * 1024,
            directory: http
        )
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JiheCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 去掉签名参数，同一份模型 / 图片不会因为 query 变了就当新文件再下。
    static func stableIdentity(_ remote: URL) -> String {
        var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        parts?.query = nil
        parts?.fragment = nil
        parts?.user = nil
        parts?.password = nil
        return parts?.string ?? remote.absoluteString
    }

    static func destination(for remote: URL, folder: String) -> URL {
        let dir = directory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
        return dir.appendingPathComponent(hash(stableIdentity(remote)) + "." + ext)
    }

    static func existingFile(for remote: URL, folder: String) -> URL? {
        if remote.isFileURL { return remote }
        let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
        let dir = directory.appendingPathComponent(folder, isDirectory: true)
        let candidates = [
            destination(for: remote, folder: folder),
            dir.appendingPathComponent(hash(remote.absoluteString) + "." + ext)
        ]
        for dest in candidates {
            if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int,
               size > 256 {
                return dest
            }
        }
        return nil
    }

    static func file(for remote: URL, folder: String) async -> URL? {
        if remote.isFileURL { return remote }
        if let hit = existingFile(for: remote, folder: folder) { return hit }
        let dest = destination(for: remote, folder: folder)
        do {
            var request = URLRequest(url: remote)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 40
            let (temp, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            return dest
        } catch {
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        }
    }

    static func cachedImage(_ remote: URL?) -> UIImage? {
        guard let remote else { return nil }
        return memory.object(forKey: remote.absoluteString as NSString)
    }

    static func image(for remote: URL?) async -> UIImage? {
        guard let remote else { return nil }
        if let hit = cachedImage(remote) { return hit }
        if let file = await file(for: remote, folder: "images"),
           let data = try? Data(contentsOf: file),
           let image = UIImage(data: data) {
            memory.setObject(image, forKey: remote.absoluteString as NSString, cost: data.count)
            return image
        }
        return nil
    }

    static func hash(_ raw: String) -> String {
        var value: UInt64 = 5381
        for byte in raw.utf8 {
            value = ((value << 5) &+ value) &+ UInt64(byte)
        }
        return String(format: "%016llx", value)
    }
}

/// 按 VIN 记住已加载过的车图 / 3D，切回来不再重新下载；GLB 路径落盘，杀进程还在。
enum HeroAssetCache {
    private static var glbFiles: [String: URL] = [:]
    private static var photos: [String: UIImage] = [:]
    private static var snapshots: [String: UIImage] = [:]
    private static var didLoadIndex = false

    static func glb(for vin: String) -> URL? {
        loadIndexIfNeeded()
        if let file = glbFiles[vin], usable(file) { return file }
        let pinned = vinGLBURL(vin)
        if usable(pinned) {
            glbFiles[vin] = pinned
            return pinned
        }
        return nil
    }

    static func rememberGLB(_ file: URL, vin: String) {
        loadIndexIfNeeded()
        guard usable(file) else { return }
        let pinned = vinGLBURL(vin)
        if file.standardizedFileURL != pinned.standardizedFileURL, !usable(pinned) {
            try? FileManager.default.createDirectory(
                at: pinned.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: pinned)
            try? FileManager.default.copyItem(at: file, to: pinned)
        }
        glbFiles[vin] = usable(pinned) ? pinned : file
        saveIndex()
    }

    private static func vinGLBURL(_ vin: String) -> URL {
        let safe = vin.replacingOccurrences(of: "/", with: "_")
        return ResourceCache.directory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("vin-\(safe)-s2.glb")
    }

    private static func usable(_ file: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int else {
            return false
        }
        return size > 1024
    }

    private static var indexURL: URL {
        ResourceCache.directory.appendingPathComponent("hero-glb.json")
    }

    private static func loadIndexIfNeeded() {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        guard let data = try? Data(contentsOf: indexURL),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        for (vin, path) in map {
            let url = URL(fileURLWithPath: path)
            if usable(url) { glbFiles[vin] = url }
        }
    }

    private static func saveIndex() {
        let map = glbFiles.mapValues(\.path)
        guard let data = try? JSONSerialization.data(withJSONObject: map) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func photo(for vin: String) -> UIImage? {
        snapshots[vin] ?? photos[vin]
    }

    static func rememberPhoto(_ image: UIImage, vin: String) {
        photos[vin] = image
    }

    static func rememberSnapshot(_ image: UIImage, vin: String) {
        snapshots[vin] = image
    }
}

enum CacheImageMode {
    case fill
    case fit
    case stretch
}

struct CachedRemoteImage: View {
    let url: URL?
    var mode: CacheImageMode = .fill
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill, stretch: Bool = false) {
        self.url = url
        if stretch {
            self.mode = .stretch
        } else {
            self.mode = contentMode == .fit ? .fit : .fill
        }
        _image = State(initialValue: ResourceCache.cachedImage(url))
    }

    var body: some View {
        Group {
            if let image {
                switch mode {
                case .stretch:
                    Image(uiImage: image)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .fit:
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .fill:
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url?.absoluteString) {
            image = ResourceCache.cachedImage(url)
            if image == nil {
                image = await ResourceCache.image(for: url)
            }
        }
    }
}

struct CachedLoopingVideo: View {
    let url: URL
    var fadeBottom: Bool = false
    /// 页面不在前台时置 false，暂停解码省 GPU
    var plays: Bool = true

    var body: some View {
        LoopingVideoView(
            url: ResourceCache.existingFile(for: url, folder: "videos") ?? url,
            muted: true,
            fadeBottom: fadeBottom,
            plays: plays
        )
            .task(id: url.absoluteString) {
                guard !url.isFileURL else { return }
                _ = await ResourceCache.file(for: url, folder: "videos")
            }
    }
}
