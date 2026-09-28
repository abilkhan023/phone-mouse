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
        case stroke
    }

    var seq: UInt32
    var kind: Kind
    var text = ""
    var keyCode: UInt8 = 0
    var modifiers: KeyModifiers = []
}

struct VolumeEvent: Equatable {
    enum Direction: UInt8 {
        case up
        case down
    }

    var seq: UInt32
    var direction: Direction
}

enum Packet: Equatable {
    case mouse(MouseReport)
    case key(KeyEvent)
    case volume(VolumeEvent)

    private static let mouseTag: UInt8 = 1
    private static let keyTag: UInt8 = 2
    private static let volumeTag: UInt8 = 3
    private static let mouseSize = 22
    private static let keyHeader = 6
    private static let volumeSize = 6

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
                  let kind = KeyEvent.Kind(rawValue: data[data.startIndex + 5]) else { return nil }
            let seq: UInt32 = data.readLittleEndian(at: 1)
            if kind == .stroke {
                guard data.count == Self.keyHeader + 2 else { return nil }
                self = .key(KeyEvent(
                    seq: seq,
                    kind: kind,
                    keyCode: data[data.startIndex + Self.keyHeader],
                    modifiers: KeyModifiers(rawValue: data[data.startIndex + Self.keyHeader + 1])
                ))
            } else {
                guard let text = String(data: data.dropFirst(Self.keyHeader), encoding: .utf8) else { return nil }
                self = .key(KeyEvent(seq: seq, kind: kind, text: text))
            }
        case Self.volumeTag:
            guard data.count == Self.volumeSize,
                  let direction = VolumeEvent.Direction(rawValue: data[data.startIndex + 5]) else { return nil }
            self = .volume(VolumeEvent(seq: data.readLittleEndian(at: 1), direction: direction))
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
            if event.kind == .stroke {
                data.append(contentsOf: [event.keyCode, event.modifiers.rawValue])
            } else {
                data.append(contentsOf: event.text.utf8)
            }
        case let .volume(event):
            data.append(Self.volumeTag)
            data.appendLittleEndian(event.seq)
            data.append(event.direction.rawValue)
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
