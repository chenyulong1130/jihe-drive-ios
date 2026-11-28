import AVFoundation
import SwiftUI

/// 相机扫码读取仪表二维码里的 Wi-Fi 名称与密码：
/// 支持 WIFI:T:WPA;S:xxx;P:yyy;; 标准格式与常见 JSON 键名；
/// 解析不出结构化字段时把原文带回，由调用页提示手动查看。
struct QRCodeScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 解析结果回调（ssid / password / 原文）
    let onResult: (_ ssid: String?, _ password: String?, _ raw: String) -> Void

    @State private var statusText = "对准仪表屏幕上的二维码"
    @State private var parsedSSID: String?
    @State private var parsedPassword: String?
    @State private var rawText = ""
    @State private var authorized = true

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(onDecoded: handleDecoded)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Text(statusText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if !rawText.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(parsedSSID != nil ? "识别成功" : "未能解析出 Wi-Fi 字段，二维码原文：")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(parsedSSID != nil ? Color.green : Color.orange)
                                Text(rawText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(4)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        HStack(spacing: 12) {
                            if parsedSSID != nil {
                                Button {
                                    onResult(parsedSSID, parsedPassword, rawText)
                                    dismiss()
                                } label: {
                                    Text("自动回填")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 26)
                                        .frame(height: 44)
                                        .background(Color.white, in: Capsule())
                                }
                            }
                            Button {
                                dismiss()
                            } label: {
                                Text("关闭")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 26)
                                    .frame(height: 44)
                                    .background(Color.white.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("扫码读取 Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                if !authorized {
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        DispatchQueue.main.async {
                            authorized = granted
                            if !granted { statusText = "相机权限被拒绝：请到系统设置开启后重试" }
                        }
                    }
                }
            }
        }
    }

    /// 同一码只处理一次，避免连拍轰炸
    private func handleDecoded(_ raw: String) {
        guard rawText != raw else { return }
        rawText = raw
        let result = Self.parseWiFi(raw)
        parsedSSID = result.ssid
        parsedPassword = result.password
        if let ssid = result.ssid {
            statusText = "已识别：\(ssid)"
        } else {
            statusText = "识别到二维码，但没有 Wi-Fi 字段"
        }
    }

    /// Wi-Fi 二维码解析：ZEEHO 仪表 URL 格式 + 标准 WIFI: 格式 + 常见 JSON 键名
    static func parseWiFi(_ raw: String) -> (ssid: String?, password: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        // 1) ZEEHO 仪表格式：URL 查询参数
        // https://zhbackend.zeehoev.com/app_download/?modelid=...&ssid=ZEEHO-xxx&pwd=xxx&auth=wpa2-psk&mac=...
        if trimmed.contains("://"), let components = URLComponents(string: trimmed),
           let items = components.queryItems {
            let values: (String) -> String? = { key in
                items.first(where: { $0.name.lowercased() == key })?.value
            }
            let ssid = values("ssid") ?? values("name") ?? values("S")
            let password = values("pwd") ?? values("password") ?? values("pass") ?? values("P")
            if let ssid, !ssid.isEmpty { return (ssid, password) }
        }

        // 2) 标准 Wi-Fi 二维码：WIFI:T:WPA;S:<ssid>;P:<pass>;H:false;;
        if trimmed.uppercased().hasPrefix("WIFI:") {
            var ssid: String?
            var password: String?
            // 处理转义分号：按未被 \ 转义的 ; 分段
            var parts: [String] = []
            var current = ""
            var iterator = trimmed.dropFirst(5).makeIterator()
            while let ch = iterator.next() {
                if ch == "\\", let next = iterator.next() {
                    current.append(next)   // 解转义 \; \\ \,
                    continue
                }
                if ch == ";" {
                    parts.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { parts.append(current) }
            for part in parts {
                if part.hasPrefix("S:"), ssid == nil {
                    ssid = String(part.dropFirst(2))
                } else if part.hasPrefix("P:"), password == nil {
                    password = String(part.dropFirst(2))
                }
            }
            if ssid != nil { return (ssid, password) }
        }

        // 2) JSON：常见键名（ssid/SSID/wifi_ssid/wifiName + password/pwd/wifi_password）
        if let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let ssidCandidates = ["ssid", "SSID", "wifi_ssid", "wifiName", "wifi_name", "S"]
            let passCandidates = ["password", "pwd", "wifi_password", "wifiPassword", "pass", "P"]
            let ssid = ssidCandidates.compactMap { object[$0] as? String }.first
            let pass = passCandidates.compactMap { object[$0] as? String }.first
            if let ssid, !ssid.isEmpty { return (ssid, pass) }
        }

        // 3) 宽松分号段：任意 text 里找 ssid=/SSID=/S: 与 pass=/password=/pwd=/P:
        var ssid: String?
        var password: String?
        for segment in trimmed.split(separator: ";") {
            let piece = segment.trimmingCharacters(in: .whitespaces)
            let lower = piece.lowercased()
            if ssid == nil {
                for key in ["ssid=", "s="] where lower.hasPrefix(key) {
                    ssid = String(piece.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
            if password == nil {
                for key in ["password=", "pwd=", "pass=", "p="] where lower.hasPrefix(key) {
                    password = String(piece.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }
        if ssid != nil { return (ssid, password) }
        return (nil, nil)
    }
}

// MARK: - 相机预览 + 元数据识别

struct CameraPreviewView: UIViewControllerRepresentable {
    let onDecoded: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onDecoded = onDecoded
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onDecoded: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var lastDecoded = ""
        private var lastAt: TimeInterval = 0

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr, .dataMatrix, .aztec, .code128]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let value = object.stringValue, !value.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if value == lastDecoded, now - lastAt < 1.5 { return }
            lastDecoded = value
            lastAt = now
            onDecoded?(value)
        }
    }
}
