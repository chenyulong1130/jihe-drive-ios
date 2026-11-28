import Foundation

/// 速牛产品目录（速调试同款种子数据 catalog-seed.json，369 个产品）：
/// 蓝牙广播名按「前缀匹配（含跳过前 2 位）取最长」命中产品，
/// 产品名含 AE7/M5/FX/角度 时自动映射调试类型——与安卓版自动识别完全一致。
/// 产品再经 productId 关联每产品独立的模式库（mode-library-seed.json）。
enum LampCatalog {

    struct Match {
        let productName: String
        let productId: Int?
    }

    private static let lock = NSLock()
    private static var loaded = false
    /// blePrefix → (productName, productId)
    private static var products: [String: (name: String, productId: Int?)] = [:]

    private static func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "catalog-seed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["bleProductNameMap"] as? [String: Any] else { return }
        var parsed: [String: (name: String, productId: Int?)] = [:]
        for (prefix, entry) in map {
            guard let product = entry as? [String: Any],
                  let name = product["productName"] as? String, !name.isEmpty else { continue }
            parsed[prefix] = (name, (product["productId"] as? NSNumber)?.intValue)
        }
        products = parsed
    }

    /// 蓝牙广播名 → 产品（最长前缀匹配；规则对齐 Protocol.matchesProductPrefix：
    /// name.hasPrefix(prefix) 或跳过前 2 位后 hasPrefix）
    static func match(for bleName: String) -> Match? {
        loadIfNeeded()
        guard !bleName.isEmpty, !products.isEmpty else { return nil }
        var bestPrefixLength = 0
        var best: Match?
        for (prefix, product) in products {
            guard !prefix.isEmpty else { continue }
            let matched = bleName.hasPrefix(prefix)
                || (bleName.count > 2 && bleName.dropFirst(2).hasPrefix(prefix))
            if matched, prefix.count > bestPrefixLength {
                bestPrefixLength = prefix.count
                best = Match(productName: product.name, productId: product.productId)
            }
        }
        return best
    }

    static func productName(for bleName: String) -> String? {
        match(for: bleName)?.productName
    }
}

// MARK: - 每产品模式库（mode-library-seed.json，15848 个模式 / 272 个产品）

/// 模式库中的一条模式：名称 / 模式号 / 所属分组，均来自云端按产品的真实数据
struct LampLibraryMode: Identifiable {
    let no: String
    let name: String
    let groupName: String
    let modeId: Int?
    let canUse: Bool

    var id: String { "\(groupName)-\(no)-\(modeId ?? -1)" }

    /// 模式号数值（"001" → 1；优先十进制，兼容十六进制写法）
    var number: Int? {
        let trimmed = no.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed) { return v }
        if let v = Int(trimmed, radix: 16) { return v }
        return nil
    }

    /// 分组名 → 本 App 的通道（行车/开机/转向/急刹）；其余分组不附加通道 TLV
    var channel: LampChannel? {
        switch groupName.lowercased() {
        case "driving": return .driving
        case "welcome": return .welcome
        case "turn": return .turn
        case "brake": return .brake
        default: return nil
        }
    }

    /// 分组中文名
    var groupTitle: String {
        switch groupName.lowercased() {
        case "driving": return "行车"
        case "welcome": return "开机"
        case "turn": return "转向"
        case "brake": return "急刹"
        case "tail", "tail1", "tail2": return "尾灯"
        case "light ring": return "灯环"
        case "shift1", "shift2": return "换挡"
        default: return groupName.isEmpty ? "其他" : groupName
        }
    }
}

enum LampModeLibrary {
    private static let lock = NSLock()
    private static var cache: [Int: [LampLibraryMode]]?

    /// productId → 该产品可用模式列表（canUse != false）
    static func modes(for productId: Int?) -> [LampLibraryMode] {
        guard let productId, let all = loadAll() else { return [] }
        return all[productId] ?? []
    }

    private static func loadAll() -> [Int: [LampLibraryMode]]? {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        guard let url = Bundle.main.url(forResource: "mode-library-seed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["products"] as? [String: Any] else { return nil }
        // 瘦身版结构：products.{productId} = { name, modes: [{ name, no, groupName, modeId }] }
        var result: [Int: [LampLibraryMode]] = [:]
        for (key, entry) in raw {
            guard let productId = Int(key),
                  let product = entry as? [String: Any],
                  let modes = product["modes"] as? [[String: Any]] else { continue }
            result[productId] = modes.compactMap { item in
                let no = (item["no"] as? String) ?? ""
                guard !no.isEmpty else { return nil }
                return LampLibraryMode(
                    no: no,
                    name: (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "模式 \(no)",
                    groupName: (item["groupName"] as? String) ?? "",
                    modeId: (item["modeId"] as? NSNumber)?.intValue,
                    canUse: true)
            }
        }
        cache = result
        return result
    }
}
