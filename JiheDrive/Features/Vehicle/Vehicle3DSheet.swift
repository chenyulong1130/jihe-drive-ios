import SceneKit
import SwiftUI

/// 3D 看车：只用接口返回的模型，没有模型就展示官方车图。
struct Vehicle3DSheet: View {
    /// 展示瞬间的快照；真实车况（坐垫/电量/3D 地址）统一走 live
    let vehicle: Vehicle

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appearance: AppearanceStore
    @StateObject private var loader = VehicleModelLoader()
    @State private var resetToken = 0
    @State private var glbFile: URL?
    @State private var glbFailed = false
    @State private var seatOpen = false
    @State private var seatToken = 0
    /// 坐垫挂载诊断文本（真机排查"点了没反应"用）
    @State private var seatDebug = ""
    /// 坐垫操作提示（真实指令结果）
    @State private var seatHint = ""
    @State private var seatBusy = false

    /// 深色主题 → 全车灯点亮（不含转向灯）；浅色 → 熄灭。只改车灯自发光，不改场景光照。
    private var lightsOn: Bool { appearance.resolvedScheme == .dark }

    // MARK: - 坐垫（真实指令 + 模型跟随）

    /// 座桶锁是电控释放：能远程"开"，关靠手动。所以：
    /// 关着时点 → 发真实解锁指令，成功后模型打开并等云端确认；
    /// 已开时点 → 只把模型合上做预览（硬件不支持远程关）。
    private func toggleSeat() async {
        guard !seatBusy else { return }
        if realSeatOpen == true {
            seatOpen = false
            seatToken += 1
            seatHint = "坐垫需手动关闭，模型已预览合上"
            return
        }
        seatBusy = true
        defer { seatBusy = false }
        do {
            try await model.openCushion(live)
            seatOpen = true
            seatToken += 1
            seatHint = "已发送开坐垫指令"
            // 尽快拉一次真实状态，让模型与实车对齐
            await model.loadBattery(vin: live.vinNo, quiet: true)
        } catch {
            seatHint = "开坐垫失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 舞台配色跟随主题（浅色下不再是深色底）

    private var stageDark: Bool { appearance.resolvedScheme == .dark }

    private var stageGradientColors: [Color] {
        stageDark
            ? [Color(hex: 0x081018), Color(hex: 0x122236), Color(hex: 0x060B10)]
            : [Color(hex: 0xE9EDF3), Color(hex: 0xF4F6F9), Color(hex: 0xDCE3EC)]
    }

    /// 舞台上的前景文字：深色舞台用白，浅色舞台用主题色
    private var stageFg: Color { stageDark ? .white : Theme.label }
    private var stageFgSoft: Color { stageDark ? Color.white.opacity(0.62) : Theme.secondary }
    private var stageFgHint: Color { stageDark ? Color.white.opacity(0.7) : Theme.secondary }

    /// sheet 内容不会随父视图刷新，入参是打开瞬间的快照——坐垫状态/3D 地址必须实时取，
    /// 否则轮询到"坐垫已打开"也进不来，模型永远保持关闭且动画不触发。
    private var live: Vehicle {
        guard let current = model.selectedVehicle,
              WidgetSnapshot.sameVin(current.vinNo, vehicle.vinNo) else { return vehicle }
        return current
    }

    private var modelURL: URL? { live.model3DURL }

    /// 云端真实坐垫状态；nil=未拿到或已过期（不拿本地 toggle 冒充）
    private var realSeatOpen: Bool? { live.seat?.isOpen() }

    private var seatCaption: String {
        guard let open = realSeatOpen else { return "未知" }
        return open ? "已打开" : "已关闭"
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                stage(height: max(340, proxy.size.height * 0.56))
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.groupedBackground.ignoresSafeArea())
        .sheetChrome()
        .task(id: vehicle.vinNo) {
            // 打开面板先按真实车况摆坐垫
            if let open = realSeatOpen {
                seatOpen = open
                seatToken += 1
            }
            if live.isGLBModel {
                await loadGLB()
            } else {
                loader.restore(vin: vehicle.vinNo, url: modelURL)
            }
            // 面板打开期间主动刷新车况：坐垫是云端状态，靠车辆页 90 秒轮询太慢，
            // 手动开/关坐垫后模型要能在一二十秒内跟上。
            while !Task.isCancelled {
                await model.loadBattery(vin: vehicle.vinNo, quiet: true)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .onChange(of: realSeatOpen) { _, open in
            // 真实坐垫状态变化：开→模型打开，关→模型关闭
            guard let open, open != seatOpen else { return }
            seatOpen = open
            seatToken += 1
        }
    }

    // MARK: - 舞台

    private func stage(height: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: stageGradientColors,
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Color(hex: 0x2F6FD0).opacity(stageDark ? 0.30 : 0.14), Color.clear],
                center: .init(x: 0.5, y: 0.44),
                startRadius: 8,
                endRadius: 260
            )

            stageContent
                .padding(.horizontal, 12)
                .padding(.top, 46)
                .padding(.bottom, 44)

            VStack {
                header
                Spacer(minLength: 0)
                if live.model3DURL != nil {
                    hint
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 28,
                bottomTrailingRadius: 28,
                topTrailingRadius: 0
            )
        )
    }

    @ViewBuilder
    private var stageContent: some View {
        if live.isGLBModel {
            glbStage
        } else if let scene = loader.scene {
            VehicleSceneView(scene: scene, interactive: true, autoSpin: true, resetToken: resetToken)
        } else {
            switch loader.state {
            case .loading:
                ModelLoadingSkeleton(scale: 1.2)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 30, weight: .light))
                    Text("模型加载失败")
                        .font(.system(size: 15, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11.5))
                        .multilineTextAlignment(.center)
                        .opacity(0.72)
                        .padding(.horizontal, 20)
                }
                .foregroundStyle(stageFg.opacity(0.9))
            default:
                photoStage
            }
        }
    }

    @ViewBuilder
    private var glbStage: some View {
        if let glbFile {
            Color.clear
                .overlay {
                    ModelViewerWebView(
                        glbFile: glbFile,
                        interactive: true,
                        autoRotate: false,
                        resetToken: resetToken,
                        lightsOn: lightsOn,
                        seatOpen: seatOpen,
                        seatToken: seatToken,
                        onSeatDebug: { text in seatDebug = text },
                        onSeatChange: { open in
                            // JS 即时回传坐垫状态（含动画过程），按钮态始终与 3D 一致
                            if seatOpen != open { seatOpen = open }
                        }
                    )
                }
        } else if glbFailed {
            VStack(spacing: 10) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 30, weight: .light))
                Text("模型下载失败")
                    .font(.system(size: 15, weight: .semibold))
                Text("接口返回的 GLB 地址无法访问，检查网络后重试")
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .opacity(0.72)
                    .padding(.horizontal, 20)
            }
            .foregroundStyle(stageFg.opacity(0.9))
        } else {
            ModelLoadingSkeleton(scale: 1.2)
        }
    }

    private func loadGLB() async {
        guard let url = modelURL, live.isGLBModel else { return }
        if let cached = GLBModelStore.cached(vin: vehicle.vinNo, remote: url) {
            glbFile = cached
            return
        }
        do {
            let file = try await GLBModelStore.localFile(for: url, vin: vehicle.vinNo)
            glbFile = file
        } catch {
            glbFailed = true
        }
    }

    private var photoStage: some View {
        VStack(spacing: 14) {
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 200, height: 14)
                    .blur(radius: 12)
                    .offset(y: 74)

                if let url = vehicle.imageURL {
                    CachedRemoteImage(url: url, contentMode: .fit)
                        .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 10)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.car.fill")
                            .font(.system(size: 46, weight: .light))
                        Text("暂无车辆图片")
                            .font(Theme.footnote)
                    }
                    .foregroundStyle(stageFgHint)
                }
            }
            .frame(maxWidth: .infinity)

            Text("该车型接口未返回 3D 模型")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(stageFgSoft)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(live.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(stageFg)
                Text(live.model3DURL != nil ? "官方 3D 模型" : "官方车辆图片")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(stageFgSoft)
            }

            Spacer(minLength: 8)

            if live.isGLBModel {
                Button {
                    Task { await toggleSeat() }
                } label: {
                    Image(systemName: "figure.seated.side")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(seatOpen ? Theme.brand : stageFg)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                .accessibilityLabel("切换模型坐垫，实际坐垫\(seatCaption)")
            }

            if live.model3DURL != nil {
                Button {
                    withAnimation(Motion.quick) { resetToken += 1 }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(stageFg)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            }

            Button {
                dismiss()
            } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(stageFg)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 10, weight: .medium))
            Text("拖动旋转 · 双指缩放 · 双击复位")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(stageFgHint)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.bottom, 14)
    }

    // MARK: - 控制区

    private var controls: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if !seatHint.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.car.fill").font(.system(size: 11))
                        Text(seatHint).font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.orange.opacity(0.12)))
                }
                AppleCard(padding: 14) {
                    VStack(spacing: 12) {
                        CardTitle(text: "整车状态", icon: "cube.transparent", tint: Theme.brand)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                            spacing: 10
                        ) {
                            metric("电量", "\(vehicle.soc)%", Theme.brand)
                            metric("续航", "\(vehicle.rangeKm) km", Theme.green)
                            metric("总里程", String(format: "%.0f km", vehicle.totalMileKm), Theme.indigo)
                            metric("车锁", vehicle.isLocked ? "已上锁" : "未锁", vehicle.isLocked ? Theme.label : Theme.orange)
                            metric("状态", vehicle.isOnline ? "在线" : "离线", vehicle.isOnline ? Theme.green : Theme.secondary)
                            metric("信号", "\(vehicle.signalLevel) 级", Theme.teal)
                            metric(
                                "坐垫",
                                seatCaption,
                                realSeatOpen == nil ? Theme.secondary
                                    : (realSeatOpen == true ? Theme.orange : Theme.label)
                            )
                        }
                    }
                }

                AppleCard(padding: 14) {
                    VStack(spacing: 0) {
                        InfoRow(title: "3D 模型", value: modelURL == nil ? "接口未提供" : "已提供")
                            .padding(.bottom, 10)
                        HairLine()
                        InfoRow(title: "VIN", value: vehicle.vinNo, mono: true)
                            .padding(.top, 10)
                        if !seatDebug.isEmpty {
                            HairLine().padding(.vertical, 10)
                            // 真机排查：模型坐垫节点是否挂上（pivot）、命中哪个节点、当前角度
                            InfoRow(title: "模型坐垫", value: seatDebug, mono: true)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    private func metric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.surfaceAlt)
        }
    }
}
