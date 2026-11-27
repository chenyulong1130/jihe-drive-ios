import Foundation

/// CarPlay 会话描述：/info 属性列表、features 位图、HID 描述符与触控报告编码。
enum CPInfo {
    static let displayID = "b7e6c5a0-2222-4000-8000-00000000e402"

    /// HID 设备 uuid（hidSendReport 用）。
    enum HID {
        static let touch = "2a2a2a2a"
        static let knob = "2a2a2a2b"
        static let media = "2a2a2a2c"
        static let telephony = "2a2a2a2d"
    }

    static let touchContacts = 2
    private static let displayFeatureKnobs: Int = 0x02
    private static let displayFeatureHighFidelityTouch: Int = 0x08
    static let defaultWidthPhysicalMM = 200

    /// 会话能力位：无音频版本（音频留在 iPhone 本机）。
    static func features(audio: Bool) -> UInt64 {
        audio ? 0x615653aee2 : 0x615653aee2 & ~UInt64(0x10004540a00)
    }

    /// CarPlay 要求 maxFPS 为 30–60、步进 5。
    static func sanitizedFPS(_ fps: Int) -> Int {
        let clamped = min(60, max(30, fps))
        return ((clamped - 30) + 2) / 5 * 5 + 30
    }

    struct Configuration {
        var name: String
        var deviceID: String
        var address: String = ""
        var width: Int
        var height: Int
        var maxFPS: Int
        var port: UInt16 = 7000
        var widthPhysicalMM: Int = defaultWidthPhysicalMM
        var rightHandDrive: Bool = false
        /// CarPlay 主屏「车辆按钮」图标：方形 PNG（边长 ≤192px）。
        /// 非空时 /info 带 oemIconVisible/oemIconLabel/oemIcons，
        /// iPhone 会在 CarPlay 主屏渲染该按钮，点按时发 requestUI 命令。
        var oemIconPNG: Data?
        /// 车辆按钮下方显示的文字。
        var oemIconLabel: String = "车辆信息"

        static func `default`(deviceID: String) -> Configuration {
            // 与极核 6.2 寸仪表一致的分辨率：CarPlay 画面可直接透传投屏
            Configuration(name: "JiheDrive", deviceID: deviceID,
                          width: 1024, height: 480, maxFPS: 30)
        }
    }

    static func build(_ config: Configuration) -> [String: Any] {
        let area: [String: Any] = ["widthPixels": config.width, "heightPixels": config.height,
                                   "originXPixels": 0, "originYPixels": 0]
        var view = area
        var safe = area
        safe["drawUIOutsideSafeArea"] = true
        view["safeArea"] = safe
        let widthPhysical = config.widthPhysicalMM
        let heightPhysical = max(1, Int((Double(widthPhysical) * Double(config.height)
            / Double(config.width)).rounded()))
        let display: [String: Any] = [
            "uuid": displayID, "type": 110, "maxFPS": sanitizedFPS(config.maxFPS),
            "widthPixels": config.width, "heightPixels": config.height,
            "widthPhysical": widthPhysical, "heightPhysical": heightPhysical,
            "features": displayFeatureHighFidelityTouch | displayFeatureKnobs,
            "primaryInputDevice": 1,
            "uiAppearanceMode": 0, "uiAppearanceSetting": 0,
            "mapAppearanceMode": 0, "mapAppearanceSetting": 0,
            "viewAreas": [view], "initialViewArea": 0,
        ]
        let resource: [String: Any] = ["resourceID": 1, "transferType": 1, "transferPriority": 100,
                                       "takeConstraint": 100, "borrowConstraint": 100,
                                       "unborrowConstraint": 100]
        let modes: [String: Any] = ["resources": [resource], "appStates": [
            ["appStateID": 2, "state": false], ["appStateID": 1, "speechMode": -1],
            ["appStateID": 3, "state": false],
        ]]
        let hidDevices = [
            hidDevice(HID.touch, name: "极核智行触控屏",
                      descriptor: touchDescriptor(width: config.width, height: config.height)),
            hidDevice(HID.knob, name: "极核智行旋钮", descriptor: knobDescriptor),
            hidDevice(HID.media, name: "极核智行多媒体键", descriptor: mediaDescriptor),
            hidDevice(HID.telephony, name: "极核智行电话键", descriptor: telephonyDescriptor),
        ]
        var info: [String: Any] = [
            "sourceVersion": "509.11",
            "features": NSNumber(value: features(audio: false)),
            "statusFlags": 4,
            "model": "JiheDrive1,1",
            "manufacturer": "JiheDrive",
            "deviceID": config.deviceID,
            "bluetoothIDs": [config.deviceID],
            "name": config.name,
            "rightHandDrive": config.rightHandDrive,
            "keepAliveLowPower": false,
            "keepAliveSendStatsAsBody": false,
            "modes": modes,
            "extendedFeatures": ["vocoderInfo", "enhancedRequestCarUI"],
            "displays": [display],
            "hidDevices": hidDevices,
        ]
        if let icon = config.oemIconPNG, let size = vehicleButtonSize(in: icon) {
            info["oemIconVisible"] = true
            info["oemIconLabel"] = config.oemIconLabel
            info["oemIcons"] = [["imageData": icon, "widthPixels": size,
                                 "heightPixels": size, "prerendered": true]]
        }
        return info
    }

    /// 从 PNG IHDR 读边长；只接受边长 1–192 的正方形，否则视为无效图标。
    static func vehicleButtonSize(in png: Data) -> Int? {
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes[0] == 0x89, bytes[1] == 0x50 else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return width == height && (1...192).contains(width) ? width : nil
    }

    private static func hidDevice(_ uuid: String, name: String, descriptor: Data) -> [String: Any] {
        ["hidProductID": 1, "hidVendorID": 2, "hidCountryCode": 0, "uuid": uuid, "name": name,
         "displayUUID": displayID, "hidDescriptor": descriptor]
    }

    // MARK: HID 报告

    struct TouchContact {
        let slot: Int
        let x: UInt16
        let y: UInt16
        let down: Bool
    }

    /// 每槽 6 字节：[slot, tip, xL, xH, yL, yH]；无接触的槽上报抬起。
    static func touchReport(_ contacts: [TouchContact]) -> Data {
        var report = Data(count: 6 * touchContacts)
        for slot in 0..<touchContacts {
            let offset = slot * 6
            report[offset] = UInt8(slot)
            guard let contact = contacts.first(where: { $0.slot == slot }) else { continue }
            report[offset + 1] = contact.down ? 1 : 0
            report[offset + 2] = UInt8(truncatingIfNeeded: contact.x)
            report[offset + 3] = UInt8(truncatingIfNeeded: contact.x >> 8)
            report[offset + 4] = UInt8(truncatingIfNeeded: contact.y)
            report[offset + 5] = UInt8(truncatingIfNeeded: contact.y >> 8)
        }
        return report
    }

    /// [select | home<<1 | back<<2, x, y, wheel]。
    static func knobReport(select: Bool = false, home: Bool = false,
                           back: Bool = false, wheel: Int8 = 0) -> Data {
        Data([(select ? 1 : 0) | (home ? 2 : 0) | (back ? 4 : 0), 0, 0,
              UInt8(bitPattern: wheel)])
    }

    enum MediaKey: UInt8 {
        case play = 1, pause = 2, playPause = 3, next = 4, previous = 5
    }

    // MARK: HID 描述符

    private static func touchDescriptor(width: Int, height: Int) -> Data {
        let finger: [UInt8] = [0x05,0x0d,0x09,0x22,0xa1,0x02,0x09,0x38,0x75,0x08,0x95,0x01,0x81,0x02,
            0x15,0x00,0x25,0x01,0x09,0x33,0x75,0x01,0x95,0x01,0x81,0x02,0x95,0x07,0x81,0x03,
            0x05,0x01,0x26,UInt8(truncatingIfNeeded: width),UInt8(truncatingIfNeeded: width >> 8),
            0x09,0x30,0x75,0x10,0x95,0x01,0x81,0x02,0x26,UInt8(truncatingIfNeeded: height),
            UInt8(truncatingIfNeeded: height >> 8),0x09,0x31,0x81,0x02,0xc0]
        return Data([0x05,0x0d,0x09,0x04,0xa1,0x01]
            + Array(repeating: finger, count: touchContacts).flatMap { $0 } + [0xc0])
    }

    /// 多轴控制器：按钮 1 = select，AC Home / AC Back，5 个填充位，
    /// 绝对 X/Y（保留 0）与相对滚轮（焦点移动）。
    private static let knobDescriptor = Data([
        0x05,0x01,0x09,0x08,0xa1,0x01,
        0x05,0x09,0x09,0x01,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x01,0x81,0x02,
        0x05,0x0c,0x0a,0x23,0x02,0x0a,0x24,0x02,0x95,0x02,0x81,0x02,
        0x95,0x05,0x81,0x01,
        0x05,0x01,0x09,0x01,0xa1,0x00,
        0x09,0x30,0x09,0x31,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x02,0x81,0x02,0xc0,
        0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x01,0x81,0x06,0xc0,
    ])

    /// 多媒体键（1 字节数组）：无 / Play / Pause / PlayPause / Next / Previous / AC Search。
    private static let mediaDescriptor = Data([
        0x05,0x0c,0x09,0x01,0xa1,0x01,0x15,0x00,0x25,0x06,0x05,0x0c,
        0x0a,0x00,0x00,0x0a,0xb0,0x00,0x0a,0xb1,0x00,0x0a,0xcd,0x00,
        0x0a,0xb5,0x00,0x0a,0xb6,0x00,0x0a,0x9e,0x02,
        0x75,0x08,0x95,0x01,0x81,0x00,0xc0,
    ])

    /// 电话键（1 字节数组）：无 / Hook Switch / Flash / Drop / Mute / 键盘删除。
    private static let telephonyDescriptor = Data([
        0x05,0x0b,0x09,0x07,0xa1,0x01,0x15,0x00,0x25,0x11,0x05,0x0b,
        0x09,0x00,0x09,0x20,0x09,0x21,0x09,0x26,0x09,0x2f,
        0x09,0xb0,0x09,0xb1,0x09,0xb2,0x09,0xb3,0x09,0xb4,0x09,0xb5,
        0x09,0xb6,0x09,0xb7,0x09,0xb8,0x09,0xb9,0x09,0xba,0x09,0xbb,
        0x05,0x07,0x09,0x2a,
        0x75,0x08,0x95,0x01,0x81,0x00,0xc0,
    ])
}
