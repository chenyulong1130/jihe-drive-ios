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

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        SheetShell(
            title: "仪表壁纸",
            subtitle: "上传后同步到车机仪表，不影响 App 主页背景",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        HStack(spacing: 10) {
                            if uploading {
                                ProgressView().scaleEffect(0.85)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.brand)
                            }
                            Text(uploading ? "正在上传…" : "制作并上传")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.label)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
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
                        }
                    }
                    .padding(.top, 4)

                    if let errorText {
                        SoftBanner(text: errorText, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                    } else if !loading && items.isEmpty {
                        Text("暂无云端壁纸，点上方按钮制作 HOME / SPEED 仪表壁纸")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items) { item in
                                wallpaperTile(item)
                            }
                        }
                    }

                    Text("设为仪表使用中请在「极核」官方 App 操作；本页可预览、上传与删除。")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.medium, .large])
        .task { await reload() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .sheet(item: $selected) { item in
            wallpaperDetail(item)
        }
    }

    private func wallpaperTile(_ item: DashboardWallpaperItem) -> some View {
        Button {
            selected = item
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let url = item.homeURL {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Theme.surfaceAlt
                                }
                            }
                        } else {
                            Theme.surfaceAlt
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if item.isLive {
                        Text("仪表使用中")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.green))
                            .padding(6)
                    }
                }

                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
    }

    private func wallpaperDetail(_ item: DashboardWallpaperItem) -> some View {
        SheetShell(title: item.name, subtitle: item.isLive ? "仪表使用中" : "云端壁纸", onClose: {
            selected = nil
        }) {
            ScrollView {
                VStack(spacing: 16) {
                    previewBlock(title: "主页 HOME", url: item.homeURL, ratio: 1024 / 600)
                    previewBlock(title: "速度卡 SPEED", url: item.speedURL, ratio: 307 / 460)

                    Text("如需设为仪表当前壁纸，请打开极核官方 App 操作。")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)

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

    private func previewBlock(title: String, url: URL?, ratio: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Theme.surfaceAlt
                        }
                    }
                } else {
                    Theme.surfaceAlt
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(ratio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
            )
        }
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

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        errorText = nil
        defer {
            uploading = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let exported = WallpaperExporter.exportAuto(from: image) else {
                errorText = "图片读取失败"
                return
            }
            let name = WallpaperExporter.nextName(existing: items.map(\.name))
            let res = try await ZeehoClient.shared.postMultipartOrdered(
                path: "/v1.0/app/cfmotoserverapp/vehicle/wallpaper/save",
                parts: [
                    .field(name: "vinNo", value: vehicle.vinNo),
                    .field(name: "wallpaperName", value: name),
                    .field(name: "types", value: "2"),
                    .file(name: "files", filename: "wallpaper_2.png", mime: "image/png", data: exported.home),
                    .field(name: "types", value: "1"),
                    .file(name: "files", filename: "wallpaper_1.png", mime: "image/png", data: exported.speed)
                ]
            )
            let code = ZeehoClient.codeString(res["code"])
            guard code == "10000" || code == "0" || code.isEmpty else {
                errorText = ZeehoClient.errorText(res) ?? "上传失败"
                return
            }
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
                isLive: live
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
