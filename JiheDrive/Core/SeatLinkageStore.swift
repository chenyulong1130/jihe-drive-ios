import Foundation
import SwiftUI

/// 3D 模型坐垫联动开关（按 VIN 记忆）。
/// 部分车型的官方 3D 模型没有坐垫节点 / 铰链位置不对，开着联动会出现
/// 「真实坐垫开了模型没反应」或「坐垫乱动」；给每台车一个开关，默认开启。
final class SeatLinkageStore: ObservableObject {
    @Published private var disabledVins: Set<String>
    private static let key = "jihe.seat.linkage.disabled.vins"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let data = raw.data(using: .utf8),
           let set = try? JSONDecoder().decode(Set<String>.self, from: data) {
            disabledVins = set
        } else {
            disabledVins = []
        }
    }

    /// 是否联动（默认开）。VIN 为空视为未换过车，保持默认开。
    func isLinked(vin: String?) -> Bool {
        guard let vin, !vin.isEmpty else { return true }
        return !disabledVins.contains(vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    func setLinked(_ linked: Bool, vin: String?) {
        guard let vin, !vin.isEmpty else { return }
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if linked {
            disabledVins.remove(key)
        } else {
            disabledVins.insert(key)
        }
        if let data = try? JSONEncoder().encode(disabledVins),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }
}
