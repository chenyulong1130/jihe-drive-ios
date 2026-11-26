import Foundation

// MARK: - 控制器协议（石栏/速牛共用 FFF0 通道）

/// 帧：[5A A5 01 ...cmd, checksum, AA]，checksum = (~sum(cmd)) & 0xFF
enum MotorProtocol {
    static func frame(_ command: [UInt8]) -> Data {
        let sum = command.reduce(0) { ($0 + Int($1)) & 0xFF }
        let check = (~sum) & 0xFF
        return Data([0x5A, 0xA5, 0x01] + command + [UInt8(check), 0xAA])
    }
}

struct MotorParams {
    var minPercent = 0
    var maxPercent = 100
    var absolutePercent = 0
    var speedLevel = 0
    var selfMode = false
    var reverse = false
    var project = 0
    var selfModeDir = 0
    var homingDir = 0
    var workingMode = 0
    var targetPercent = 0
}

enum MotorEvent {
    case ack
    case invalid
    case moved(absolute: Int, target: Int)
    case busy
    case selfTestStart
    case selfTestDone(absolute: Int, target: Int)
    case homingDone(absolute: Int, target: Int)
    case params(MotorParams)
    case unknown(Int)
}

/// 通知分片 → 完整控制器帧
final class MotorFrameDecoder {
    private var buffer: [UInt8] = []

    func feed(_ chunk: Data) -> [[UInt8]] {
        buffer.append(contentsOf: chunk)
        if buffer.count > 4096 { buffer.removeFirst(buffer.count - 4096) }

        var frames: [[UInt8]] = []
        var index = 0
        while index + 4 <= buffer.count {
            guard buffer[index] == 0x5A, buffer[index + 1] == 0xA5 else {
                index += 1
                continue
            }
            let length = Int(buffer[index + 3])
            guard length >= 2 else {
                index += 4
                continue
            }
            let total = 4 + length
            if index + total > buffer.count { break }
            let tail = buffer[index + total - 1]
            let receivedChecksum = buffer[index + total - 2]
            // 校验 = ~(长度字节起共 length-1 字节之和)：e[3..length+1]，不含校验码自身
            // （对齐 motor_handle 小程序 processCommand：g=0..<d-1 累加 e[3+g]）
            let sum = (index + 3..<(index + total - 2)).reduce(0) { ($0 + Int(buffer[$1])) & 0xFF }
            guard tail == 0xAA, receivedChecksum == ((~sum) & 0xFF) else {
                index += 1
                continue
            }
            frames.append(Array(buffer[index..<(index + total)]))
            index += total
        }
        if index > 0 { buffer.removeFirst(index) }
        return frames
    }
}

extension MotorProtocol {
    static func parse(_ frame: [UInt8]) -> MotorEvent? {
        guard frame.count >= 8, frame[4] == 15 else { return nil }
        guard frame[2] == 1 else { return nil } // 应答标志
        let sub = frame[5]
        func pair(at offset: Int) -> (Int, Int) {
            guard frame.count > offset + 1 else { return (0, 0) }
            return (Int(frame[offset]), Int(frame[offset + 1]))
        }
        switch sub {
        case 0:
            return .ack
        case 1:
            return .invalid
        case 2:
            let p = pair(at: 6)
            return .moved(absolute: p.0, target: p.1)
        case 3:
            return .busy
        case 7:
            let p = pair(at: 6)
            return .selfTestDone(absolute: p.0, target: p.1)
        case 8:
            let p = pair(at: 6)
            return .homingDone(absolute: p.0, target: p.1)
        case 9:
            let p = pair(at: 6)
            return .homingDone(absolute: p.0, target: p.1)
        case 11:
            guard frame.count >= 17 else { return nil }
            var params = MotorParams()
            params.minPercent = Int(frame[6])
            params.maxPercent = Int(frame[7])
            params.absolutePercent = Int(frame[8])
            params.speedLevel = Int(frame[9])
            params.selfMode = frame[10] != 0
            params.reverse = frame[11] != 0
            params.project = Int(frame[12])
            if params.project > 12 { params.project = 0 }
            params.selfModeDir = Int(frame[13])
            params.homingDir = Int(frame[14])
            params.workingMode = Int(frame[15])
            params.targetPercent = Int(frame[16])
            guard params.maxPercent > params.minPercent,
                  params.maxPercent <= 100,
                  params.speedLevel <= 10 else { return nil }
            return .params(params)
        default:
            return .unknown(Int(sub))
        }
    }
}

/// 13 个车型预设，参数表与 motor_handle/index.js 一致
struct MotorProject: Identifiable {
    let index: Int
    let name: String
    let min: Int
    let max: Int
    let direction: Int
    let reverseFlag: Int
    let isReverse: Bool

    var id: Int { index }

    static let all: [MotorProject] = {
        let names = [
            "默认", "FX", "9号01", "9号02", "AE4", "AE2", "NX",
            "E80", "M5", "MZ1-30", "M3-100", "NST", "NX-马拉松"
        ]
        return names.enumerated().map { index, name in
            var min = 0, max = 100, direction = 0, reverseFlag = 0
            var isReverse = false
            switch index {
            case 1, 4, 5:
                direction = 1; reverseFlag = 1
            case 2, 3:
                max = 60; isReverse = true
            case 6:
                min = 50; max = 100; direction = 1; reverseFlag = 1
            case 7...11:
                direction = 1
            case 12:
                max = 75; direction = 1; reverseFlag = 1
            default:
                break
            }
            return MotorProject(
                index: index, name: name, min: min, max: max,
                direction: direction, reverseFlag: reverseFlag, isReverse: isReverse
            )
        }
    }()
}
