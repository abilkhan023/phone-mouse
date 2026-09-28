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
    // True while fingers rest on the touchpad in a scroll. Sent as a state in
    // every report, like the buttons, so the Mac can tell when a scroll starts
    // and ends even if reports are lost, and glide on after it ends.
    var isScrolling = false
}

extension KeyEvent.Kind {
    var carriesKey: Bool { self == .stroke || self == .hold || self == .release }
}

struct KeyEvent: Equatable {
    enum Kind: UInt8 {
        case text
        case backspace
        case enter
        case stroke
        // Modifiers pressed down and let go, for keys held on the phone.
        case hold
        case release
    }

    var seq: UInt32
    var kind: Kind
    // For text, the characters. For backspace, how many times to press it;
    // empty means once.
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

struct GestureEvent: Equatable {
    enum Kind: UInt8 {
        case swipeUp
        case swipeDown
        case swipeLeft
        case swipeRight
        case pinchIn
        case spreadOut
        case lookUp
        case zoomIn
        case zoomOut
        // Quick actions from the remote.
        case lockScreen
        case screenshot
        case screenshotArea
        case screenshotTools
        case displaySleep
        case forceQuit
        case emoji
    }

    var seq: UInt32
    var kind: Kind
}

struct ClipboardItem: Equatable {
    enum Kind: UInt8 {
        case text
        case png
    }

    static let sizeLimit = 20 * 1024 * 1024

    var kind: Kind
    var data: Data
}

enum Packet: Equatable {
    case mouse(MouseReport)
    case key(KeyEvent)
    case volume(VolumeEvent)
    case gesture(GestureEvent)
    // The Mac confirms the key events it has typed, so the phone can send
    // again whatever got lost.
    case ack(UInt32)
    // Round trips for the latency shown on the phone.
    case ping(UInt32)
    case pong(UInt32)
    // The Mac's clipboard port. The clipboard goes over TCP, since an image
    // can be megabytes.
    case clipboardPort(UInt16)
    case clipboard(ClipboardItem)
    // Pairing by code travels in the clear; see CodePairing.
    case pairHello(publicKey: Data)
    case pairReply(publicKey: Data)
    case pairCommit(round: UInt8, Data)
    case pairCommitReply(round: UInt8, Data)
    case pairReveal(round: UInt8, Data)
    case pairRevealReply(round: UInt8, Data)
    case pairReject

    private static let mouseTag: UInt8 = 1
    private static let keyTag: UInt8 = 2
    private static let volumeTag: UInt8 = 3
    private static let gestureTag: UInt8 = 4
    private static let ackTag: UInt8 = 5
    private static let helloTag: UInt8 = 6
    private static let replyTag: UInt8 = 7
    private static let commitTag: UInt8 = 8
    private static let commitReplyTag: UInt8 = 9
    private static let revealTag: UInt8 = 10
    private static let revealReplyTag: UInt8 = 11
    private static let rejectTag: UInt8 = 12
    private static let pingTag: UInt8 = 13
    private static let pongTag: UInt8 = 14
    private static let clipboardPortTag: UInt8 = 15
    private static let clipboardTag: UInt8 = 16
    private static let field = 32
    private static let mouseSize = 23
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
                scrollY: Float(bitPattern: data.readLittleEndian(at: 18)),
                isScrolling: data[data.startIndex + 22] & 1 != 0
            ))
        case Self.keyTag:
            guard data.count >= Self.keyHeader,
                  let kind = KeyEvent.Kind(rawValue: data[data.startIndex + 5]) else { return nil }
            let seq: UInt32 = data.readLittleEndian(at: 1)
            if kind.carriesKey {
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
        case Self.gestureTag:
            guard data.count == Self.volumeSize,
                  let kind = GestureEvent.Kind(rawValue: data[data.startIndex + 5]) else { return nil }
            self = .gesture(GestureEvent(seq: data.readLittleEndian(at: 1), kind: kind))
        case Self.ackTag, Self.pingTag, Self.pongTag:
            guard data.count == 5 else { return nil }
            let value: UInt32 = data.readLittleEndian(at: 1)
            switch tag {
            case Self.ackTag: self = .ack(value)
            case Self.pingTag: self = .ping(value)
            default: self = .pong(value)
            }
        case Self.clipboardPortTag:
            guard data.count == 3 else { return nil }
            self = .clipboardPort(UInt16(data[data.startIndex + 1]) | UInt16(data[data.startIndex + 2]) << 8)
        case Self.clipboardTag:
            guard data.count >= 2, let kind = ClipboardItem.Kind(rawValue: data[data.startIndex + 1]) else { return nil }
            self = .clipboard(ClipboardItem(kind: kind, data: Data(data.dropFirst(2))))
        case Self.helloTag, Self.replyTag:
            guard data.count == 1 + Self.field else { return nil }
            let key = Data(data.suffix(Self.field))
            self = tag == Self.helloTag ? .pairHello(publicKey: key) : .pairReply(publicKey: key)
        case Self.commitTag, Self.commitReplyTag, Self.revealTag, Self.revealReplyTag:
            guard data.count == 2 + Self.field else { return nil }
            let round = data[data.startIndex + 1]
            let value = Data(data.suffix(Self.field))
            switch tag {
            case Self.commitTag: self = .pairCommit(round: round, value)
            case Self.commitReplyTag: self = .pairCommitReply(round: round, value)
            case Self.revealTag: self = .pairReveal(round: round, value)
            default: self = .pairRevealReply(round: round, value)
            }
        case Self.rejectTag:
            guard data.count == 1 else { return nil }
            self = .pairReject
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
            data.append(report.isScrolling ? 1 : 0)
        case let .key(event):
            data.append(Self.keyTag)
            data.appendLittleEndian(event.seq)
            data.append(event.kind.rawValue)
            if event.kind.carriesKey {
                data.append(contentsOf: [event.keyCode, event.modifiers.rawValue])
            } else {
                data.append(contentsOf: event.text.utf8)
            }
        case let .volume(event):
            data.append(Self.volumeTag)
            data.appendLittleEndian(event.seq)
            data.append(event.direction.rawValue)
        case let .gesture(event):
            data.append(Self.gestureTag)
            data.appendLittleEndian(event.seq)
            data.append(event.kind.rawValue)
        case let .ack(seq):
            data.append(Self.ackTag)
            data.appendLittleEndian(seq)
        case let .ping(id):
            data.append(Self.pingTag)
            data.appendLittleEndian(id)
        case let .pong(id):
            data.append(Self.pongTag)
            data.appendLittleEndian(id)
        case let .clipboardPort(port):
            data.append(contentsOf: [Self.clipboardPortTag, UInt8(port & 0xff), UInt8(port >> 8)])
        case let .clipboard(item):
            data.append(contentsOf: [Self.clipboardTag, item.kind.rawValue])
            data.append(item.data)
        case let .pairHello(publicKey):
            data.append(Self.helloTag)
            data.append(publicKey)
        case let .pairReply(publicKey):
            data.append(Self.replyTag)
            data.append(publicKey)
        case let .pairCommit(round, value):
            data.append(contentsOf: [Self.commitTag, round])
            data.append(value)
        case let .pairCommitReply(round, value):
            data.append(contentsOf: [Self.commitReplyTag, round])
            data.append(value)
        case let .pairReveal(round, value):
            data.append(contentsOf: [Self.revealTag, round])
            data.append(value)
        case let .pairRevealReply(round, value):
            data.append(contentsOf: [Self.revealReplyTag, round])
            data.append(value)
        case .pairReject:
            data.append(Self.rejectTag)
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
