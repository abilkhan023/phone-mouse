import Foundation

enum BonjourService {
    static let type = "_phonemouse._udp"
}

struct MouseButtons: OptionSet {
    let rawValue: UInt8

    static let left = MouseButtons(rawValue: 1 << 0)
    static let right = MouseButtons(rawValue: 1 << 1)
}

struct MouseReport: Equatable {
    static let size = 21

    var seq: UInt32 = 0
    var buttons: MouseButtons = []
    var dx: Float = 0
    var dy: Float = 0
    var scrollX: Float = 0
    var scrollY: Float = 0
}

extension MouseReport {
    init?(data: Data) {
        guard data.count == Self.size else { return nil }
        seq = data.readLittleEndian(at: 0)
        buttons = MouseButtons(rawValue: data[data.startIndex + 4])
        dx = Float(bitPattern: data.readLittleEndian(at: 5))
        dy = Float(bitPattern: data.readLittleEndian(at: 9))
        scrollX = Float(bitPattern: data.readLittleEndian(at: 13))
        scrollY = Float(bitPattern: data.readLittleEndian(at: 17))
    }

    func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.appendLittleEndian(seq)
        data.append(buttons.rawValue)
        for value in [dx, dy, scrollX, scrollY] {
            data.appendLittleEndian(value.bitPattern)
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndian(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        let start = startIndex + offset
        Swift.withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: self[start..<start + 4]) }
        return UInt32(littleEndian: value)
    }
}
