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
    var seq: UInt32 = 0
    var buttons: MouseButtons = []
    var dx: Float = 0
    var dy: Float = 0
    var scrollX: Float = 0
    var scrollY: Float = 0
}

struct KeyEvent: Equatable {
    enum Kind: UInt8 {
        case text
        case backspace
        case enter
    }

    var seq: UInt32
    var kind: Kind
    var text = ""
}

enum Packet: Equatable {
    case mouse(MouseReport)
    case key(KeyEvent)

    private static let mouseTag: UInt8 = 1
    private static let keyTag: UInt8 = 2
    private static let mouseSize = 22
    private static let keyHeader = 6

    init?(data: Data) {
        guard let tag = data.first else { return nil }
        switch tag {
        case Self.mouseTag:
            guard data.count == Self.mouseSize else { return nil }
            self = .mouse(MouseReport(
                seq: data.readLittleEndian(at: 1),
                buttons: MouseButtons(rawValue: data[data.startIndex + 5]),
                dx: Float(bitPattern: data.readLittleEndian(at: 6)),
                dy: Float(bitPattern: data.readLittleEndian(at: 10)),
                scrollX: Float(bitPattern: data.readLittleEndian(at: 14)),
                scrollY: Float(bitPattern: data.readLittleEndian(at: 18))
            ))
        case Self.keyTag:
            guard data.count >= Self.keyHeader,
                  let kind = KeyEvent.Kind(rawValue: data[data.startIndex + 5]),
                  let text = String(data: data.dropFirst(Self.keyHeader), encoding: .utf8) else { return nil }
            self = .key(KeyEvent(seq: data.readLittleEndian(at: 1), kind: kind, text: text))
        default:
            return nil
        }
    }

    func encoded() -> Data {
        var data = Data()
        switch self {
        case let .mouse(report):
            data.append(Self.mouseTag)
            data.appendLittleEndian(report.seq)
            data.append(report.buttons.rawValue)
            for value in [report.dx, report.dy, report.scrollX, report.scrollY] {
                data.appendLittleEndian(value.bitPattern)
            }
        case let .key(event):
            data.append(Self.keyTag)
            data.appendLittleEndian(event.seq)
            data.append(event.kind.rawValue)
            data.append(contentsOf: event.text.utf8)
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
