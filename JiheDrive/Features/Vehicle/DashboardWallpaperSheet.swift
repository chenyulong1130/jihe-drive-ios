import PhotosUI
import SwiftUI
import UIKit

/// 车机仪表壁纸：云端列表 / 制作上传 / 删除
/// 与 Flutter VehicleWallpaperSheet 对齐；启用仍需在极核官方 App 操作
struct DashboardWallpaperSheet: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss

    @State private var items: [DashboardWallpaperItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var selected: DashboardWallpaperItem?
    @State private var deleting = false
    @State private var draftImage: UIImage?
    @State private var draftHome: UIImage?
    @State private var draftSpeed: UIImage?

    private var outlines: WallpaperOutlines {
        (vehicle.wallpaperOutlines ?? .fallback).withFallback()
    }

    var body: some View {
        SheetShell(
            title: "仪表壁纸",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("制作壁纸")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.label)
                                Text("选图后先预览仪表轮廓再上传")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.surface)
                        )
                    }
                    .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
                    .disabled(uploading)

                    HStack {
                        Text("云端壁纸")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        if loading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("\(items.count)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .padding(.top, 2)

                    if let errorText {
                        SoftBanner(text: errorText, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                    } else if !loading && items.isEmpty {
                        Text("暂无壁纸")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)
                            ],
                            spacing: 10
                        ) {
                            ForEach(items) { item in
                                wallpaperTile(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.medium, .large])
        .task {
            async let preloadHome: UIImage? = ResourceCache.image(for: outlines.homeOutlineURL)
            async let preloadSpeed: UIImage? = ResourceCache.image(for: outlines.speedOutlineURL)
            async let preloadSubject: UIImage? = ResourceCache.image(for: outlines.speedSubjectURL)
            _ = await (preloadHome, preloadSpeed, preloadSubject)
            await reload()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await prepareDraft(item) }
        }
        .sheet(item: $selected) { item in
            wallpaperDetail(item)
        }
        .sheet(isPresented: Binding(
            get: { draftImage != nil },
            set: { if !$0 { clearDraft() } }
        )) {
            draftPreviewSheet
        }
    }

    private func wallpaperTile(_ item: DashboardWallpaperItem) -> some View {
        Button {
            selected = item
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: 0x1C1C1E))
                    if let url = item.homeURL {
                        CachedRemoteImage(url: url, contentMode: .fill)
                    }
                    WallpaperOutlineLayer(
                        url: (item.outlines ?? vehicle.wallpaperOutlines)?.withFallback().homeOutlineURL,
                        onDark: false
                    )
                    if item.isLive {
                        Text("使用中")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.green.opacity(0.92)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(
                    CGFloat(WallpaperExporter.homeW) / CGFloat(WallpaperExporter.homeH),
                    contentMode: .fit
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                )

                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.isLive ? "仪表使用中" : "云端已保存")
                    .font(.system(size: 11))
                    .foregroundStyle(item.isLive ? Theme.green : Theme.tertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
    }

    private var draftPreviewSheet: some View {
        SheetShell(title: "轮廓预览", subtitle: "确认后再上传到云端", onClose: { clearDraft() }) {
            ScrollView {
                VStack(spacing: 14) {
                    if let home = draftHome {
                        labeledFrame(title: "主页") {
                            instrumentFrame(dark: false) {
                                ZStack {
                                    fillPhoto(home)
                                    WallpaperOutlineLayer(url: outlines.homeOutlineURL, onDark: false)
                                }
                            }
                        }
                    }
                    if let home = draftHome, let speed = draftSpeed {
                        labeledFrame(title: "速度卡") {
                            instrumentFrame(dark: true) {
                                ZStack {
                                    fillPhoto(home)
                                    speedSlot(fillPhoto(speed))
                                    WallpaperOutlineLayer(url: outlines.speedOutlineURL, onDark: true)
                                }
                            }
                        }
                    }

                    Button {
                        Task { await confirmUpload() }
                    } label: {
                        HStack {
                            if uploading { ProgressView().tint(.white) }
                            Text(uploading ? "上传中…" : "确认上传")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.brand)
                        )
                    }
                    .disabled(uploading)
                    .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.large])
    }

    private func wallpaperDetail(_ item: DashboardWallpaperItem) -> some View {
        SheetShell(title: item.name, subtitle: item.isLive ? "仪表使用中" : "云端壁纸", onClose: {
            selected = nil
        }) {
            ScrollView {
                VStack(spacing: 16) {
                    labeledFrame(title: "主页") {
                        instrumentFrame(dark: false) {
                            ZStack {
                                if let url = item.homeURL {
                                    CachedRemoteImage(url: url, contentMode: .fill)
                                }
                                WallpaperOutlineLayer(
                                    url: (item.outlines ?? vehicle.wallpaperOutlines)?.withFallback().homeOutlineURL,
                                    onDark: false
                                )
                            }
                        }
                    }
                    labeledFrame(title: "速度卡") {
                        instrumentFrame(dark: true) {
                            ZStack {
                                if let url = item.homeURL {
                                    CachedRemoteImage(url: url, contentMode: .fill)
                                }
                                if let url = item.speedURL {
                                    speedSlot(CachedRemoteImage(url: url, contentMode: .fill))
                                }
                                WallpaperOutlineLayer(
                                    url: (item.outlines ?? vehicle.wallpaperOutlines)?.withFallback().speedOutlineURL,
                                    onDark: true
                                )
                            }
                        }
                    }

                    Button(role: .destructive) {
                        Task { await delete(item) }
                    } label: {
                        HStack {
                            if deleting {
                                ProgressView().tint(Theme.red)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("删除此壁纸")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.surface)
                        )
                    }
                    .disabled(deleting || item.id.isEmpty)
                    .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.medium, .large])
    }

    private func labeledFrame<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    )
                    .padding(8)
            }
    }

    /// 仪表统一 1024×600 预览帧。先定宽高，再叠图，避免按图片自身比例被拉高。
    private func instrumentFrame<Content: View>(dark: Bool, @ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(
                CGFloat(WallpaperExporter.homeW) / CGFloat(WallpaperExporter.homeH),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .background(dark ? Color(hex: 0x0A0A0C) : Color(hex: 0xB8B8C0))
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(dark ? 0.16 : 0.2), lineWidth: 1)
            )
    }

    private func fillPhoto(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    /// 速度卡叠回主页 (358, 54, 307×460) 槽位，与导出裁切一致
    private func speedSlot<Content: View>(_ content: Content) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let x = CGFloat(WallpaperExporter.speedCropX) / CGFloat(WallpaperExporter.homeW) * w
            let y = CGFloat(WallpaperExporter.speedCropY) / CGFloat(WallpaperExporter.homeH) * h
            let sw = CGFloat(WallpaperExporter.speedW) / CGFloat(WallpaperExporter.homeW) * w
            let sh = CGFloat(WallpaperExporter.speedH) / CGFloat(WallpaperExporter.homeH) * h
            content
                .frame(width: sw, height: sh)
                .clipped()
                .offset(x: x, y: y)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Network

    private func reload() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let res = try await ZeehoClient.shared.get(
                "/v1.0/app/cfmotoserverapp/vehicle/wallpaper/pageVehicleWallpaper",
                query: [
                    "vinNo": vehicle.vinNo,
                    "pageNum": "1",
                    "pageSize": "50"
                ]
            )
            let code = ZeehoClient.codeString(res["code"])
            guard code == "10000" || code == "0" || code.isEmpty else {
                errorText = ZeehoClient.errorText(res) ?? "加载失败"
                return
            }
            items = DashboardWallpaperItem.parseList(res["data"])
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func prepareDraft(_ item: PhotosPickerItem) async {
        errorText = nil
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let exported = WallpaperExporter.exportAuto(from: image) else {
            errorText = "图片读取失败"
            return
        }
        draftImage = image
        draftHome = UIImage(data: exported.home)
        draftSpeed = UIImage(data: exported.speed)
    }

    private func clearDraft() {
        draftImage = nil
        draftHome = nil
        draftSpeed = nil
    }

    private func confirmUpload() async {
        guard let home = draftHome?.pngData(),
              let speed = draftSpeed?.pngData() else { return }
        uploading = true
        errorText = nil
        defer { uploading = false }
        do {
            let name = WallpaperExporter.nextName(existing: items.map(\.name))
            let res = try await ZeehoClient.shared.postMultipartOrdered(
                path: "/v1.0/app/cfmotoserverapp/vehicle/wallpaper/save",
                parts: [
                    .field(name: "vinNo", value: vehicle.vinNo),
                    .field(name: "wallpaperName", value: name),
                    .field(name: "types", value: "2"),
                    .file(name: "files", filename: "wallpaper_2.png", mime: "image/png", data: home),
                    .field(name: "types", value: "1"),
                    .file(name: "files", filename: "wallpaper_1.png", mime: "image/png", data: speed)
                ]
            )
            let code = ZeehoClient.codeString(res["code"])
            guard code == "10000" || code == "0" || code.isEmpty else {
                errorText = ZeehoClient.errorText(res) ?? "上传失败"
                return
            }
            clearDraft()
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ item: DashboardWallpaperItem) async {
        guard !item.id.isEmpty else { return }
        deleting = true
        defer { deleting = false }
        do {
            let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.id
            let res = try await ZeehoClient.shared.delete(
                "/v1.0/app/cfmotoserverapp/vehicle/wallpaper/deleteWallpaperV2/\(encoded)"
            )
            let code = ZeehoClient.codeString(res["code"])
            guard code == "10000" || code == "0" || code.isEmpty else {
                errorText = ZeehoClient.errorText(res) ?? "删除失败"
                return
            }
            selected = nil
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct DashboardWallpaperItem: Identifiable, Hashable {
    let id: String
    let name: String
    let homeURL: URL?
    let speedURL: URL?
    let isLive: Bool
    var outlines: WallpaperOutlines? = nil

    static func parseList(_ data: Any?) -> [DashboardWallpaperItem] {
        let rawList: [[String: Any]]
        if let list = data as? [[String: Any]] {
            rawList = list
        } else if let map = data as? [String: Any] {
            rawList = (map["list"] as? [[String: Any]])
                ?? (map["records"] as? [[String: Any]])
                ?? []
        } else {
            rawList = []
        }

        return rawList.compactMap { map in
            let id = firstString(map, keys: ["id", "wallpaperId", "wallpaperInfoId", "pkId"]) ?? UUID().uuidString
            let name = (map["wallpaperName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let live = "\(map["useState"] ?? "")" == "1" || (map["useState"] as? Int) == 1
            return DashboardWallpaperItem(
                id: id,
                name: (name?.isEmpty == false ? name! : "未命名"),
                homeURL: parseContentURL(map["wallpaperContent"], type: "2"),
                speedURL: parseContentURL(map["wallpaperContent"], type: "1"),
                isLive: live,
                outlines: WallpaperOutlines.parse(map["wallpaperConfigSnapshot"] ?? map["subjectWallpaperConfig"])
            )
        }
    }

    private static func firstString(_ map: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = map[key], "\(value)".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func parseContentURL(_ raw: Any?, type: String) -> URL? {
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for entry in arr {
            if "\(entry["type"] ?? "")" == type,
               let url = entry["url"] as? String,
               !url.isEmpty {
                return URL(string: url)
            }
        }
        return nil
    }
}

/// 官方仪表轮廓：主页按原图叠；速度卡提亮成白线（对齐 Flutter wallpaper_frame_preview）
private struct WallpaperOutlineLayer: View {
    let url: URL?
    var onDark: Bool

    var body: some View {
        if let url {
            if onDark {
                ZStack {
                    CachedRemoteImage(url: url, stretch: true)
                        .colorMultiply(Color.white.opacity(0.82))
                    CachedRemoteImage(url: url, stretch: true)
                        .blendMode(.screen)
                        .opacity(0.4)
                }
                .allowsHitTesting(false)
            } else {
                CachedRemoteImage(url: url, stretch: true)
                    .opacity(0.92)
                    .allowsHitTesting(false)
            }
        }
    }
}
