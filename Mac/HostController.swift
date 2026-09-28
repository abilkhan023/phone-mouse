import AppKit
import CryptoKit
import Network
import Observation

@Observable
final class HostController {
    private(set) var isClientActive = false
    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var pairing: Pairing
    // Changes each time a phone connects, so the pairing window knows to close.
    private(set) var connections = 0
    // A phone asking to pair by code, shown in the pairing window.
    private(set) var comparison: Comparison?
    let needsPairing: Bool

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var pending: [NWConnection] = []
    @ObservationIgnored private var channel: SecureChannel
    @ObservationIgnored private var lastCounter: UInt64
    @ObservationIgnored private var savedCounter: UInt64
    @ObservationIgnored private var sendCounter: UInt64 = 0
    @ObservationIgnored private var lastSeq: UInt32?
    @ObservationIgnored private var lastKeySeq: UInt32?
    @ObservationIgnored private var lastVolumeSeq: UInt32?
    @ObservationIgnored private var lastGestureSeq: UInt32?
    @ObservationIgnored private var lastReportAt: TimeInterval = 0
    @ObservationIgnored private var offers: [ObjectIdentifier: Offer] = [:]
    @ObservationIgnored private var isPairingOpen = false

    struct Comparison: Equatable {
        let code: String
        fileprivate let id: ObjectIdentifier
    }

    private struct Offer {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let macNonce = CodePairing.newNonce()
        let phoneKey: Data
        let connection: NWConnection
        var phoneNonce: Data?
        var isAllowed = false

        var macKey: Data { privateKey.publicKey.rawRepresentation }
    }

    private let driver = CursorDriver()
    private let keyboard = KeyboardDriver()
    private let silenceTimeout = 0.5
    private let pendingLimit = 4
    private let offerLimit = 8
    private let keyWindow: Int32 = 1000
    private static let counterKey = "lastCounter"

    init() {
        let pairing: Pairing
        if let stored = PairingStore.load(), stored.hostName == Self.serviceName {
            pairing = stored
            needsPairing = false
        } else {
            pairing = Pairing.generate(hostName: Self.serviceName)
            PairingStore.save(pairing)
            needsPairing = true
        }
        self.pairing = pairing
        channel = SecureChannel(key: pairing.key)
        lastCounter = UInt64(UserDefaults.standard.string(forKey: Self.counterKey) ?? "") ?? 0
        savedCounter = lastCounter
        startListener()
        startWatchdog()
        if !isTrusted {
            requestAccess()
        }
    }

    // A new code makes the old one useless, so a phone paired before has to
    // scan again.
    func resetPairing() {
        adopt(Pairing.generate(hostName: Self.serviceName))
        connection?.cancel()
        connection = nil
        disconnect()
    }

    // Pairing by code is only open while the pairing window is.
    func beginCodePairing() {
        isPairingOpen = true
    }

    // An allowed offer stays, so the phone still gets its confirmation if the
    // first one was lost.
    func endCodePairing() {
        isPairingOpen = false
        offers = offers.filter { $0.value.isAllowed }
        comparison = nil
    }

    func allowComparison() {
        guard let comparison, var offer = offers[comparison.id], let phoneNonce = offer.phoneNonce,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: offer.phoneKey),
              let secret = try? offer.privateKey.sharedSecretFromKeyAgreement(with: publicKey) else { return }
        let key = CodePairing.sessionKey(
            secret: secret,
            phoneKey: offer.phoneKey,
            macKey: offer.macKey,
            phoneNonce: phoneNonce,
            macNonce: offer.macNonce
        )
        offer.isAllowed = true
        offers = [comparison.id: offer]
        self.comparison = nil
        adopt(Pairing(hostName: Self.serviceName, keyData: key))
        send(.ack(0), on: offer.connection)
        connections += 1
    }

    func denyComparison() {
        guard let comparison else { return }
        offers[comparison.id] = nil
        self.comparison = nil
    }

    private func adopt(_ pairing: Pairing) {
        self.pairing = pairing
        PairingStore.save(pairing)
        channel = SecureChannel(key: pairing.key)
    }

    private static var serviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startListener() {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVoice
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.service = NWListener.Service(name: Self.serviceName, type: BonjourService.type)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: silenceTimeout, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // A new connection only replaces the current one after it sends a packet
    // sealed with the paired key, so strangers cannot knock the phone off.
    private func accept(_ connection: NWConnection) {
        pending.append(connection)
        if pending.count > pendingLimit {
            let dropped = pending.removeFirst()
            offers[ObjectIdentifier(dropped)] = nil
            dropped.cancel()
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, connection === self.connection || self.pending.contains(where: { $0 === connection }) else { return }
            if let data {
                self.dispatch(data, from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                connection.cancel()
                self.pending.removeAll { $0 === connection }
                self.offers[ObjectIdentifier(connection)] = nil
            }
        }
    }

    private func dispatch(_ data: Data, from connection: NWConnection) {
        if let (packet, counter) = channel.open(data, from: .phone) {
            guard counter > lastCounter else { return }
            lastCounter = counter
            promote(connection)
            switch packet {
            case let .mouse(report): handle(report)
            case let .key(event): handle(event)
            case let .volume(event): handle(event)
            case let .gesture(event): handle(event)
            default: break
            }
            return
        }
        switch Packet(data: data) {
        case let .pairHello(phoneKey): offer(to: connection, phoneKey: phoneKey)
        case let .pairNonce(nonce): exchange(nonce, from: connection)
        default: break
        }
    }

    private func offer(to connection: NWConnection, phoneKey: Data) {
        guard isPairingOpen, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey)) != nil else { return }
        let id = ObjectIdentifier(connection)
        if offers[id]?.phoneKey != phoneKey {
            guard offers.count < offerLimit else { return }
            offers[id] = Offer(phoneKey: phoneKey, connection: connection)
        }
        guard let offer = offers[id] else { return }
        let commitment = CodePairing.commitment(macNonce: offer.macNonce, macKey: offer.macKey, phoneKey: phoneKey)
        connection.send(content: Packet.pairReply(publicKey: offer.macKey, commitment: commitment).encoded(), completion: .idempotent)
    }

    // The phone's nonce is taken once, so it cannot be swapped after the Mac's
    // nonce is out.
    private func exchange(_ phoneNonce: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var offer = offers[id], offer.phoneNonce == nil || offer.phoneNonce == phoneNonce else { return }
        if offer.isAllowed {
            send(.ack(0), on: connection)
            return
        }
        offer.phoneNonce = phoneNonce
        offers[id] = offer
        connection.send(content: Packet.pairNonceReply(offer.macNonce).encoded(), completion: .idempotent)
        let code = CodePairing.code(phoneKey: offer.phoneKey, macKey: offer.macKey, phoneNonce: phoneNonce, macNonce: offer.macNonce)
        if comparison?.id != id {
            comparison = Comparison(code: code, id: id)
        }
    }

    private func send(_ packet: Packet, on connection: NWConnection) {
        sendCounter = SecureChannel.counter(after: sendCounter)
        guard let data = channel.seal(packet, counter: sendCounter, from: .mac) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    private func promote(_ connection: NWConnection) {
        guard connection !== self.connection else { return }
        pending.removeAll { $0 === connection }
        offers[ObjectIdentifier(connection)] = nil
        self.connection?.cancel()
        self.connection = connection
        lastSeq = nil
        lastVolumeSeq = nil
        lastGestureSeq = nil
        connections += 1
    }

    private func disconnect() {
        pending.forEach { $0.cancel() }
        pending = []
        if isClientActive {
            isClientActive = false
            driver.releaseButtons()
        }
    }

    private func handle(_ report: MouseReport) {
        if let lastSeq, Int32(bitPattern: report.seq &- lastSeq) <= 0 { return }
        lastSeq = report.seq
        lastReportAt = ProcessInfo.processInfo.systemUptime
        if !isClientActive {
            isClientActive = true
        }
        driver.apply(report)
    }

    // Key events arrive as an ordered stream that the phone keeps sending until
    // they are acknowledged. The next one in line is typed, repeats and events
    // past a gap are dropped. A jump far away means the app started a new
    // stream, which begins at a random number.
    private func handle(_ event: KeyEvent) {
        let gap = lastKeySeq.map { Int32(bitPattern: event.seq &- $0) }
        switch gap {
        case .some(1), nil:
            apply(event)
        case let .some(step) where step > 1 && step < keyWindow:
            break
        case let .some(step) where step <= 0 && step > -keyWindow:
            break
        default:
            apply(event)
        }
        if let lastKeySeq, let connection {
            send(.ack(lastKeySeq), on: connection)
        }
    }

    private func apply(_ event: KeyEvent) {
        lastKeySeq = event.seq
        keyboard.apply(event)
    }

    private func handle(_ event: VolumeEvent) {
        if let lastVolumeSeq, Int32(bitPattern: event.seq &- lastVolumeSeq) <= 0 { return }
        lastVolumeSeq = event.seq
        keyboard.apply(event)
    }

    private func handle(_ event: GestureEvent) {
        if let lastGestureSeq, Int32(bitPattern: event.seq &- lastGestureSeq) <= 0 { return }
        lastGestureSeq = event.seq
        keyboard.apply(event)
    }

    private func check() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        if lastCounter != savedCounter {
            savedCounter = lastCounter
            UserDefaults.standard.set(String(lastCounter), forKey: Self.counterKey)
        }
        if isClientActive, let connection {
            send(.ack(lastKeySeq ?? 0), on: connection)
        }
        guard isClientActive, ProcessInfo.processInfo.systemUptime - lastReportAt > silenceTimeout else { return }
        isClientActive = false
        driver.releaseButtons()
    }
}
