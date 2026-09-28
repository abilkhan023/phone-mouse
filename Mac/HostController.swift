import AppKit
import Network
import Observation

@Observable
final class HostController {
    private(set) var isClientActive = false
    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var pairing: Pairing
    let needsPairing: Bool

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var pending: [NWConnection] = []
    @ObservationIgnored private var channel: SecureChannel
    @ObservationIgnored private var lastCounter: UInt64
    @ObservationIgnored private var savedCounter: UInt64
    @ObservationIgnored private var lastSeq: UInt32?
    @ObservationIgnored private var lastKeySeq: UInt32?
    @ObservationIgnored private var lastVolumeSeq: UInt32?
    @ObservationIgnored private var lastReportAt: TimeInterval = 0

    private let driver = CursorDriver()
    private let keyboard = KeyboardDriver()
    private let silenceTimeout = 0.5
    private let pendingLimit = 4
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
        pairing = Pairing.generate(hostName: Self.serviceName)
        PairingStore.save(pairing)
        channel = SecureChannel(key: pairing.key)
        connection?.cancel()
        connection = nil
        disconnect()
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
            pending.removeFirst().cancel()
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, connection === self.connection || self.pending.contains(where: { $0 === connection }) else { return }
            if let data, let (packet, counter) = self.channel.open(data), counter > self.lastCounter {
                self.lastCounter = counter
                self.promote(connection)
                switch packet {
                case let .mouse(report): self.handle(report)
                case let .key(event): self.handle(event)
                case let .volume(event): self.handle(event)
                }
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                connection.cancel()
                self.pending.removeAll { $0 === connection }
            }
        }
    }

    private func promote(_ connection: NWConnection) {
        guard connection !== self.connection else { return }
        pending.removeAll { $0 === connection }
        self.connection?.cancel()
        self.connection = connection
        lastSeq = nil
        lastKeySeq = nil
        lastVolumeSeq = nil
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

    private func handle(_ event: KeyEvent) {
        if let lastKeySeq, Int32(bitPattern: event.seq &- lastKeySeq) <= 0 { return }
        lastKeySeq = event.seq
        keyboard.apply(event)
    }

    private func handle(_ event: VolumeEvent) {
        if let lastVolumeSeq, Int32(bitPattern: event.seq &- lastVolumeSeq) <= 0 { return }
        lastVolumeSeq = event.seq
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
        guard isClientActive, ProcessInfo.processInfo.systemUptime - lastReportAt > silenceTimeout else { return }
        isClientActive = false
        driver.releaseButtons()
    }
}
