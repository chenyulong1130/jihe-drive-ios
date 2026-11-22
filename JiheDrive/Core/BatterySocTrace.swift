import Foundation

/// 本地 SOC 采样。官方没有电量历史接口，对齐几何面板 / 小程序：
/// 有效 soc（1…100）写入本机，同一 VIN 15 秒内覆盖末点，每车最多 600 条。
struct BatterySample: Identifiable, Codable, Hashable {
    var t: Double
    var soc: Int
    var c: Bool
    var v: Double?
    var a: Double?
    var w: Double?

    var id: Double { t }

    var date: Date { Date(timeIntervalSince1970: t / 1000) }
}

enum BatterySocTrace {
    static let maxCount = 600
    static let gapMs: Double = 15_000

    static func load(vin: String) -> [BatterySample] {
        guard !vin.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(vin)),
              let list = try? JSONDecoder().decode([BatterySample].self, from: data) else {
            return []
        }
        return list
    }

    @discardableResult
    static func record(
        vin: String,
        soc: Int,
        charging: Bool,
        voltage: Double? = nil,
        current: Double? = nil,
        power: Double? = nil
    ) -> [BatterySample] {
        guard (1...100).contains(soc), !vin.isEmpty else { return load(vin: vin) }
        var list = load(vin: vin)
        let now = Date().timeIntervalSince1970 * 1000
        if let last = list.last, now - last.t < gapMs {
            list[list.count - 1] = BatterySample(
                t: last.t,
                soc: soc,
                c: charging,
                v: voltage ?? last.v,
                a: current ?? last.a,
                w: power ?? last.w
            )
        } else {
            list.append(
                BatterySample(t: now, soc: soc, c: charging, v: voltage, a: current, w: power)
            )
            if list.count > maxCount {
                list.removeFirst(list.count - maxCount)
            }
        }
        persist(vin: vin, list)
        return list
    }

    static func clear(vin: String) {
        UserDefaults.standard.removeObject(forKey: key(vin))
    }

    /// 近 48 点直取；全部则聚成 48 桶（小程序 BUCKET_N）。
    static func view(_ samples: [BatterySample], rangeAll: Bool) -> [BatterySample] {
        if !rangeAll { return Array(samples.suffix(48)) }
        return bucket(samples)
    }

    static func bucket(_ samples: [BatterySample], n: Int = 48) -> [BatterySample] {
        let arr = Array(samples.suffix(maxCount))
        guard arr.count > n else { return arr }
        let size = Double(arr.count) / Double(n)
        var out: [BatterySample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let start = Int(Double(i) * size)
            let end = min(arr.count, max(start + 1, Int(Double(i + 1) * size)))
            guard start < end else { continue }
            let slice = arr[start..<end]
            let sum = slice.reduce(0) { $0 + $1.soc }
            let last = slice.last!
            out.append(
                BatterySample(
                    t: last.t,
                    soc: Int((Double(sum) / Double(slice.count)).rounded()),
                    c: slice.contains(where: \.c),
                    v: last.v,
                    a: last.a,
                    w: last.w
                )
            )
        }
        return out
    }

    /// 最近 30 分钟采样做最小二乘，推算充满剩余分钟。几何面板 / 小程序兜底。
    static func estimateFullMinutes(samples: [BatterySample], currentSoc: Int, now: Date = Date()) -> Int? {
        let cutoff = now.timeIntervalSince1970 * 1000 - 30 * 60 * 1000
        let pts = samples.filter { $0.soc > 0 && $0.t >= cutoff }
        guard pts.count >= 3, currentSoc < 100 else { return nil }
        let t0 = pts[0].t
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        let n = Double(pts.count)
        for p in pts {
            let x = (p.t - t0) / 60_000
            let y = Double(p.soc)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let denom = n * sxx - sx * sx
        guard denom > 0.01 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let remain = Double(100 - currentSoc)
        guard slope > 0.05, remain > 0 else { return nil }
        let minutes = Int((remain / slope).rounded())
        guard minutes > 0, minutes < 24 * 60 else { return nil }
        return minutes
    }

    static func clock(_ sample: BatterySample) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: sample.date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    static func minutesText(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
        }
        return "\(minutes) 分钟"
    }

    private static func key(_ vin: String) -> String { "jihe.soc.trace.\(vin)" }

    private static func persist(vin: String, _ list: [BatterySample]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key(vin))
        }
    }
}
