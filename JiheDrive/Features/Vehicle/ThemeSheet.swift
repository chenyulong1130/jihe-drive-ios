import PhotosUI
import SwiftUI
import UIKit

/// 打开面板时优先定位到哪一段
enum ThemeFocus {
    case none
    case wallpaper
    case theme
}

struct ThemeSheet: View {
    var focus: ThemeFocus = .none

    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @Environment(\.dismiss) private var dismiss

    @State private var videoItem: PhotosPickerItem?
    @State private var photoItem: PhotosPickerItem?
    @State private var working: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        SheetShell(title: "车辆背景", onClose: { dismiss() }) {
            ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    SectionHeader("我的")
                    mineCard

                    SectionHeader("动态视频主题")
                        .id("theme")
                    LazyVGrid(columns: columns, spacing: 12) {
                        defaultThemeCell
                        ForEach(VehicleThemeCatalog.videoThemes) { theme in
                            videoThemeCell(theme)
                        }
                    }

                    SectionHeader("程序动态")
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AnimatedBackdropKind.allCases) { kind in
                            animatedCell(kind)
                        }
                    }

                    SectionHeader("内置渐变")
                        .id("wallpaper")
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(WallpaperCatalog.all) { wallpaper in
                            wallpaperCell(wallpaper)
                        }
                    }

                    if let error = videoStore.errorText {
                        SoftBanner(text: error, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 32)
            }
            .onAppear {
                guard focus != .none else { return }
                let target = focus == .wallpaper ? "wallpaper" : "theme"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(Motion.spring) {
                        reader.scrollTo(target, anchor: .top)
                    }
                }
            }
            }
        }
        .sheetChrome()
    }

    // MARK: - 我的

    private var mineCard: some View {
        VStack(spacing: 0) {
            PhotosPicker(selection: $videoItem, matching: .videos, photoLibrary: .shared()) {
                mediaRow(
                    icon: "video.fill",
                    title: "我的视频",
                    detail: videoStore.hasVideo ? "已设置" : "未设置",
                    active: themeStore.selectedID == ThemeStore.videoID,
                    busy: working == "video"
                )
            }
            .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))

            HairLine(inset: 54)

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                mediaRow(
                    icon: "photo.fill",
                    title: "我的照片",
                    detail: wallpaperStore.hasWallpaper ? "已设置" : "未设置",
                    active: themeStore.selectedID == ThemeStore.photoID,
                    busy: working == "photo"
                )
            }
            .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))

            if videoStore.hasVideo || wallpaperStore.hasWallpaper {
                HairLine(inset: 54)

                Button {
                    videoStore.clear()
                    wallpaperStore.clear()
                    if themeStore.selectedID == ThemeStore.videoID || themeStore.selectedID == ThemeStore.photoID {
                        themeStore.select(WallpaperCatalog.all[0].id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.red)
                            .frame(width: 22)
                        Text("清除我的素材")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.red)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task { await importVideo(item) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
    }

    private func mediaRow(icon: String, title: String, detail: String, active: Bool, busy: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.brand.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.brand)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.label)
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView().scaleEffect(0.7)
            } else if active {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.brand)
            } else {
                Text("选择")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.brand)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .contentShape(Rectangle())
    }

    // MARK: - 壁纸格子

    private func wallpaperCell(_ wallpaper: BuiltInWallpaper) -> some View {
        let selected = themeStore.selectedID == wallpaper.id
        return Button {
            withAnimation(Motion.quick) { themeStore.select(wallpaper.id) }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    BuiltInWallpaperView(wallpaper: wallpaper)
                        .frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 2.4)
                        )

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, Theme.brand)
                            .padding(6)
                    }
                }

                Text(wallpaper.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.brand : Theme.secondary)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    private func animatedCell(_ kind: AnimatedBackdropKind) -> some View {
        let selected = themeStore.selectedID == kind.rawValue
        return Button {
            withAnimation(Motion.quick) { themeStore.select(kind.rawValue) }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AnimatedBackdrop(kind: kind)
                        .frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 2.4)
                        )
                        .overlay(alignment: .bottomLeading) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(6)
                        }

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, Theme.brand)
                            .padding(6)
                    }
                }

                Text(kind.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.brand : Theme.secondary)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    // MARK: - 动态视频主题

    private var defaultThemeCell: some View {
        let selected = themeStore.selectedID.isEmpty
        return Button {
            withAnimation(Motion.quick) { themeStore.select("") }
            dismiss()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surfaceAlt)
                        .frame(height: 92)
                    Image(systemName: "circle.slash")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, Theme.brand)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 2.4)
                )

                Text("默认")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.brand : Theme.secondary)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    private func videoThemeCell(_ theme: VehicleTheme) -> some View {
        let selected = themeStore.selectedID == theme.id
        return Button {
            withAnimation(Motion.quick) { themeStore.select(theme.id) }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let poster = theme.posterURL {
                            AsyncImage(url: poster) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom)
                                }
                            }
                        } else {
                            LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 2.4)
                    )
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(6)
                    }

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, Theme.brand)
                            .padding(6)
                    }
                }

                Text(theme.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.brand : Theme.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    // MARK: - 导入

    private func importVideo(_ item: PhotosPickerItem) async {
        working = "video"
        defer { working = nil }
        do {
            guard let transfer = try await item.loadTransferable(type: VideoTransfer.self) else {
                videoStore.errorText = "读取视频失败，换一个试试"
                return
            }
            try await videoStore.save(from: transfer.url)
            try? FileManager.default.removeItem(at: transfer.url)
            withAnimation(Motion.quick) { themeStore.select(ThemeStore.videoID) }
        } catch {
            videoStore.errorText = error.localizedDescription
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        working = "photo"
        defer { working = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            return
        }
        wallpaperStore.save(image)
        withAnimation(Motion.quick) { themeStore.select(ThemeStore.photoID) }
    }
}
