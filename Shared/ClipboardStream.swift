import Foundation
import Network

// One TCP connection that carries sealed packets as frames: a four-byte
// length followed by the sealed bytes. Used for the clipboard, whose images
// are too big for datagrams.
final class ClipboardStream {
    var onPacket: ((Packet) -> Void)?
    var onClose: (() -> Void)?

    let connection: NWConnection
    private let channel: SecureChannel
    private let sender: SecureChannel.Sender
    private let seal: (Packet) -> Data?
    private var lastCounter: UInt64 = 0
    private var closed = false

    init(connection: NWConnection, channel: SecureChannel, receivesFrom sender: SecureChannel.Sender, seal: @escaping (Packet) -> Data?) {
        self.connection = connection
        self.channel = channel
        self.sender = sender
        self.seal = seal
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        if connection.state == .setup {
            connection.start(queue: .main)
        }
        readFrame()
    }

    func send(_ packet: Packet) {
        guard !closed, let body = seal(packet) else { return }
        var frame = Data()
        Swift.withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, !self.closed else { return }
            guard let header, header.count == 4, error == nil else {
                self.close()
                return
            }
            var length: UInt32 = 0
            Swift.withUnsafeMutableBytes(of: &length) { $0.copyBytes(from: header) }
            let size = Int(UInt32(littleEndian: length))
            guard size > 0, size <= ClipboardItem.sizeLimit + 1024 else {
                self.close()
                return
            }
            self.connection.receive(minimumIncompleteLength: size, maximumLength: size) { body, _, _, error in
                guard !self.closed else { return }
                guard let body, body.count == size, error == nil else {
                    self.close()
                    return
                }
                if let (packet, counter) = self.channel.open(body, from: self.sender), counter > self.lastCounter {
                    self.lastCounter = counter
                    self.onPacket?(packet)
                }
                self.readFrame()
            }
        }
    }
}
