import UIKit

/// 仪表壁纸导出：1024×600 主页 + 从主页裁出的 307×460 速度卡
/// 裁切参数与 Flutter WallpaperExporter / 小程序 wallpaperExport 对齐
enum WallpaperExporter {
    static let homeW = 1024
    static let homeH = 600
    static let speedW = 307
    static let speedH = 460
    static let speedCropX = 358
    static let speedCropY = 54

    static func exportAuto(from image: UIImage) -> (home: Data, speed: Data)? {
        guard let home = exportHome(from: image),
              let homeImage = UIImage(data: home),
              let speed = exportSpeed(from: homeImage) else {
            return nil
        }
        return (home, speed)
    }

    static func exportHome(from image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: homeW, height: homeH),
            format: format
        )
        let rendered = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: homeW, height: homeH))

            let iw = image.size.width
            let ih = image.size.height
            guard iw > 0, ih > 0 else { return }
            let scale = max(CGFloat(homeW) / iw, CGFloat(homeH) / ih)
            let dw = iw * scale
            let dh = ih * scale
            let x = (CGFloat(homeW) - dw) / 2
            let y = (CGFloat(homeH) - dh) / 2
            image.draw(in: CGRect(x: x, y: y, width: dw, height: dh))
        }
        return rendered.pngData()
    }

    static func exportSpeed(from home: UIImage) -> Data? {
        guard let cg = home.cgImage else { return nil }
        let scale = home.scale
        let rect = CGRect(
            x: CGFloat(speedCropX) * scale,
            y: CGFloat(speedCropY) * scale,
            width: CGFloat(speedW) * scale,
            height: CGFloat(speedH) * scale
        )
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up).pngData()
    }

    /// 下一个「自定义壁纸N」名称
    static func nextName(existing: [String]) -> String {
        let digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        var used = Set<Int>()
        let pattern = try? NSRegularExpression(pattern: #"^自定义壁纸([一二三四五六七八九十\d]+)$"#)
        for name in existing {
            guard let pattern,
                  let match = pattern.firstMatch(
                    in: name,
                    range: NSRange(name.startIndex..., in: name)
                  ),
                  let range = Range(match.range(at: 1), in: name) else { continue }
            let token = String(name[range])
            if let n = Int(token) {
                used.insert(n)
            } else if let idx = digits.firstIndex(of: token) {
                used.insert(idx + 1)
            }
        }
        var next = 1
        while used.contains(next) { next += 1 }
        if next <= digits.count {
            return "自定义壁纸\(digits[next - 1])"
        }
        return "自定义壁纸\(next)"
    }
}
