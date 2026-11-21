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

    static func destination(for remote: URL, folder: String) -> URL {
        let dir = directory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
        return dir.appendingPathComponent(hash(remote.absoluteString) + "." + ext)
    }

    static func existingFile(for remote: URL, folder: String) -> URL? {
        if remote.isFileURL { return remote }
        let dest = destination(for: remote, folder: folder)
        if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int,
           size > 256 {
            return dest
        }
        return nil
    }

    static func file(for remote: URL, folder: String) async -> URL? {
        if remote.isFileURL { return remote }
        let dest = destination(for: remote, folder: folder)
        if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int,
           size > 256 {
            return dest
        }
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

/// 按 VIN 记住已加载过的车图 / 3D，切回来不再重新下载
enum HeroAssetCache {
    private static var glbFiles: [String: URL] = [:]
    private static var photos: [String: UIImage] = [:]
    private static var snapshots: [String: UIImage] = [:]

    static func glb(for vin: String) -> URL? { glbFiles[vin] }

    static func rememberGLB(_ file: URL, vin: String) {
        glbFiles[vin] = file
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

    var body: some View {
        LoopingVideoView(
            url: ResourceCache.existingFile(for: url, folder: "videos") ?? url,
            muted: true,
            fadeBottom: fadeBottom
        )
            .task(id: url.absoluteString) {
                guard !url.isFileURL else { return }
                _ = await ResourceCache.file(for: url, folder: "videos")
            }
    }
}
