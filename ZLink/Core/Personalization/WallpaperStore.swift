import SwiftUI
import UIKit

/// 本地壁纸：存 Documents 目录，重装前一直有效
@MainActor
final class WallpaperStore: ObservableObject {
    @Published private(set) var image: UIImage?

    private let fileURL: URL
    private static let fileName = "vehicle-wallpaper.jpg"

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = directory.appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: fileURL) {
            image = UIImage(data: data)
        }
    }

    var hasWallpaper: Bool { image != nil }

    func save(_ picked: UIImage) {
        let scaled = picked.scaledToMaxSide(2200)
        guard let data = scaled.jpegData(compressionQuality: 0.88) else { return }
        try? data.write(to: fileURL, options: .atomic)
        image = scaled
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }
}

extension UIImage {
    func scaledToMaxSide(_ maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return self }
        let ratio = maxSide / longest
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
