import PhotosUI
import SwiftUI
import UIKit

/// 车辆背景：视频、照片、内置动态主题、静态主题、云端封面
struct ThemeSheet: View {
    @EnvironmentObject private var store: ThemeStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @EnvironmentObject private var photoStore: WallpaperStore
    @Environment(\.dismiss) private var dismiss

    @State private var videoItem: PhotosPickerItem?
    @State private var photoItem: PhotosPickerItem?
    @State private var notice: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        SheetShell(
            title: "车辆背景",
            subtitle: "视频 · 照片 · 动态 · 静态",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("我的背景")
                    mediaCard

                    if let notice {
                        SoftBanner(text: notice, icon: "info.circle", tone: Theme.orange)
                    }

                    SectionHeader("动态主题")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(AnimatedBackdropKind.allCases) { kind in
                            animatedCell(kind)
                        }
                    }

                    SectionHeader("静态主题")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(VehicleThemeCatalog.all.filter { $0.posterURL == nil }) { theme in
                            cell(theme)
                        }
                    }

                    SectionHeader("云端封面")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(VehicleThemeCatalog.all.filter { $0.posterURL != nil }) { theme in
                            cell(theme)
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .overlay {
                if videoStore.importing {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("正在处理视频")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task { await importVideo(item) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
    }

    // MARK: - 我的

    private var mediaCard: some View {
        AppleCard(padding: EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)) {
            VStack(spacing: 0) {
                videoRow
                HairLine().padding(.leading, 68)
                photoRow
            }
        }
    }

    private var videoRow: some View {
        HStack(spacing: 12) {
            Button {
                guard videoStore.hasVideo else { return }
                select(ThemeStore.videoID)
            } label: {
                HStack(spacing: 12) {
                    mediaThumb(image: videoStore.poster, symbol: "play.rectangle.fill")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("我的视频")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Theme.label)
                        Text(videoStatus)
                            .font(Theme.footnote)
                            .foregroundStyle(store.selectedID == ThemeStore.videoID ? Theme.brand : Theme.secondary)
                    }

                    Spacer(minLength: 0)

                    if store.selectedID == ThemeStore.videoID {
                        checkMark
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))

            PhotosPicker(selection: $videoItem, matching: .videos) {
                pill(videoStore.hasVideo ? "更换" : "选择")
            }
            .disabled(videoStore.importing)
            .contextMenu {
                if videoStore.hasVideo {
                    Button(role: .destructive) {
                        videoStore.clear()
                        if store.selectedID == ThemeStore.videoID {
                            store.select("")
                        }
                    } label: {
                        Label("移除视频", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var photoRow: some View {
        HStack(spacing: 12) {
            Button {
                guard photoStore.hasWallpaper else { return }
                select(ThemeStore.photoID)
            } label: {
                HStack(spacing: 12) {
                    mediaThumb(image: photoStore.image, symbol: "photo")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("我的照片")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Theme.label)
                        Text(photoStatus)
                            .font(Theme.footnote)
                            .foregroundStyle(store.selectedID == ThemeStore.photoID ? Theme.brand : Theme.secondary)
                    }

                    Spacer(minLength: 0)

                    if store.selectedID == ThemeStore.photoID {
                        checkMark
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))

            PhotosPicker(selection: $photoItem, matching: .images) {
                pill(photoStore.hasWallpaper ? "更换" : "选择")
            }
            .contextMenu {
                if photoStore.hasWallpaper {
                    Button(role: .destructive) {
                        photoStore.clear()
                        if store.selectedID == ThemeStore.photoID {
                            store.select("")
                        }
                    } label: {
                        Label("移除照片", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var videoStatus: String {
        guard videoStore.hasVideo else { return "从相册选一段视频，静音循环播放" }
        return store.selectedID == ThemeStore.videoID ? "正在使用 · 循环播放" : "点按使用"
    }

    private var photoStatus: String {
        guard photoStore.hasWallpaper else { return "静态图片，可当封面" }
        return store.selectedID == ThemeStore.photoID ? "正在使用" : "点按使用"
    }

    private func mediaThumb(image: UIImage?, symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceAlt)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionStrong)
            .foregroundStyle(Theme.brand)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule(style: .continuous).fill(Theme.brand.opacity(0.12)))
    }

    private var checkMark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(Theme.brand)
    }

    // MARK: - 主题格

    private func animatedCell(_ kind: AnimatedBackdropKind) -> some View {
        let selected = store.selectedID == kind.rawValue

        return Button {
            select(kind.rawValue)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AnimatedBackdrop(kind: kind)
                    .frame(height: 88)
                    .overlay(alignment: .bottomLeading) {
                        Text("动态")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.28)))
                            .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if selected { checkBadge }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(kind.desc)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func cell(_ theme: VehicleTheme) -> some View {
        let selected = store.selectedID == theme.id

        return Button {
            select(theme.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                preview(theme)
                    .frame(height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if selected { checkBadge }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(theme.desc)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var checkBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.white, Theme.brand)
            .padding(6)
    }

    @ViewBuilder
    private func preview(_ theme: VehicleTheme) -> some View {
        ZStack {
            LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            if let poster = theme.posterURL {
                AsyncImage(url: poster) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }

            Image(systemName: "bolt.car")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
        }
    }

    // MARK: - 动作

    private func select(_ id: String) {
        withAnimation(Motion.spring) { store.select(id) }
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        notice = nil
        defer { videoItem = nil }
        do {
            guard let transfer = try await item.loadTransferable(type: VideoTransfer.self) else {
                notice = BackdropError.exportFailed.errorDescription
                return
            }
            defer { try? FileManager.default.removeItem(at: transfer.url) }
            try await videoStore.save(from: transfer.url)
            videoStore.errorText = nil
            select(ThemeStore.videoID)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        notice = nil
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                notice = "这张照片读不出来，换一张试试"
                return
            }
            photoStore.save(image)
            select(ThemeStore.photoID)
        } catch {
            notice = error.localizedDescription
        }
    }
}
