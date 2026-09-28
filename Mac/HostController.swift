import AppKit
import Network
import Observation

@Observable
final class HostController {
    private(set) var isClientActive = false
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var lastSeq: UInt32?
    @ObservationIgnored private var lastKeySeq: UInt32?
    @ObservationIgnored private var lastReportAt: TimeInterval = 0

    private let driver = CursorDriver()
    private let keyboard = KeyboardDriver()
    private let silenceTimeout = 0.5

    init() {
        startListener()
        startWatchdog()
        if !isTrusted {
            requestAccess()
        }
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
        listener.service = NWListener.Service(name: Host.current().localizedName, type: BonjourService.type)
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

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        lastSeq = nil
        lastKeySeq = nil
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, connection === self.connection else { return }
            if let data, let packet = Packet(data: data) {
                switch packet {
                case let .mouse(report): self.handle(report)
                case let .key(event): self.handle(event)
                }
            }
            if error == nil {
                self.receive(on: connection)
            }
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

    private func check() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        guard isClientActive, ProcessInfo.processInfo.systemUptime - lastReportAt > silenceTimeout else { return }
        isClientActive = false
        driver.releaseButtons()
    }
}
