import Foundation

/// 从 GLB 里摘掉不该出现的零件节点（充电口盖 / 灯点），对齐 Flutter & 小程序。
enum GLBNodeStripper {
    static let stripNames = ["C-Plug", "C-Plug2", "C-LightPoint"]

    private static let magic: UInt32 = 0x46546C67 // glTF
    private static let jsonChunk: UInt32 = 0x4E4F534A
    private static let binChunk: UInt32 = 0x004E4942

    static func strip(_ input: Data, names: [String] = stripNames) -> Data {
        guard input.count >= 20, !names.isEmpty else { return input }

        let bytes = [UInt8](input)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        guard u32(0) == magic else { return input }

        var jsonData: Data?
        var binData = Data()
        var offset = 12
        while offset + 8 <= bytes.count {
            let len = Int(u32(offset))
            let type = u32(offset + 4)
            guard len > 0, offset + 8 + len <= bytes.count else { break }
            let chunk = Data(bytes[(offset + 8)..<(offset + 8 + len)])
            if type == jsonChunk { jsonData = chunk }
            if type == binChunk { binData = chunk }
            offset += 8 + len
        }
        guard var jsonData,
              var root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              var nodes = root["nodes"] as? [[String: Any]],
              !nodes.isEmpty else {
            return input
        }

        let targets = Set(names)
        var remove = Set<Int>()
        for (i, node) in nodes.enumerated() {
            if let name = node["name"] as? String, targets.contains(name) {
                remove.insert(i)
            }
        }
        var changed = true
        while changed {
            changed = false
            for i in remove {
                if let kids = nodes[i]["children"] as? [Int] {
                    for k in kids where remove.insert(k).inserted {
                        changed = true
                    }
                }
            }
        }
        guard !remove.isEmpty else { return input }

        var oldToNew: [Int: Int] = [:]
        var kept: [[String: Any]] = []
        for (i, node) in nodes.enumerated() where !remove.contains(i) {
            oldToNew[i] = kept.count
            kept.append(node)
        }

        func remap(_ src: [Any]?) -> [Int] {
            guard let src else { return [] }
            var out: [Int] = []
            for value in src {
                guard let v = value as? Int, !remove.contains(v), let n = oldToNew[v] else { continue }
                out.append(n)
            }
            return out
        }

        for i in kept.indices {
            if kept[i]["children"] != nil {
                kept[i]["children"] = remap(kept[i]["children"] as? [Any])
            }
        }
        root["nodes"] = kept

        if var scenes = root["scenes"] as? [[String: Any]] {
            for i in scenes.indices {
                if scenes[i]["nodes"] != nil {
                    scenes[i]["nodes"] = remap(scenes[i]["nodes"] as? [Any])
                }
            }
            root["scenes"] = scenes
        }

        if var anims = root["animations"] as? [[String: Any]] {
            var newAnims: [[String: Any]] = []
            for anim in anims {
                var m = anim
                var channels: [[String: Any]] = []
                if let raw = m["channels"] as? [[String: Any]] {
                    for c in raw {
                        var cm = c
                        if var tgt = cm["target"] as? [String: Any], let node = tgt["node"] as? Int {
                            if remove.contains(node) { continue }
                            guard let nn = oldToNew[node] else { continue }
                            tgt["node"] = nn
                            cm["target"] = tgt
                        }
                        channels.append(cm)
                    }
                }
                if !channels.isEmpty {
                    m["channels"] = channels
                    newAnims.append(m)
                }
            }
            root["animations"] = newAnims
        }

        if var skins = root["skins"] as? [[String: Any]] {
            var newSkins: [[String: Any]] = []
            var dropped = Set<Int>()
            for (i, skin) in skins.enumerated() {
                var m = skin
                if m["joints"] != nil {
                    m["joints"] = remap(m["joints"] as? [Any])
                }
                if let skel = m["skeleton"] as? Int {
                    if remove.contains(skel) {
                        m.removeValue(forKey: "skeleton")
                    } else if let n = oldToNew[skel] {
                        m["skeleton"] = n
                    }
                }
                if let joints = m["joints"] as? [Int], joints.isEmpty {
                    dropped.insert(i)
                    continue
                }
                newSkins.append(m)
            }
            root["skins"] = newSkins
            if !dropped.isEmpty {
                for i in kept.indices {
                    if let s = kept[i]["skin"] as? Int, dropped.contains(s) {
                        kept[i].removeValue(forKey: "skin")
                    }
                }
                root["nodes"] = kept
            }
        }

        guard let newJSON = try? JSONSerialization.data(withJSONObject: root, options: []) else {
            return input
        }
        return pack(json: newJSON, bin: binData)
    }

    private static func pack(json: Data, bin: Data) -> Data {
        let jPad = (4 - (json.count % 4)) % 4
        var jChunk = json
        jChunk.append(contentsOf: Array(repeating: UInt8(0x20), count: jPad))

        let bPad = (4 - (bin.count % 4)) % 4
        var bChunk = bin
        bChunk.append(contentsOf: Array(repeating: UInt8(0), count: bPad))

        let total = 12 + 8 + jChunk.count + 8 + bChunk.count
        var out = Data(capacity: total)
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        appendU32(magic)
        appendU32(2)
        appendU32(UInt32(total))
        appendU32(UInt32(jChunk.count))
        appendU32(jsonChunk)
        out.append(jChunk)
        appendU32(UInt32(bChunk.count))
        appendU32(binChunk)
        out.append(bChunk)
        return out
    }
}
