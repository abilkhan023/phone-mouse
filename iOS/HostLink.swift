import Foundation
import Network

final class HostLink {
    var onHostChange: ((String?) -> Void)?
    var pairing: Pairing? {
        didSet {
            channel = pairing.map { SecureChannel(key: $0.key) }
            guard pairing != oldValue, wifiMonitor != nil else { return }
            browse(peerToPeer: !hasWifi)
        }
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var wifiMonitor: NWPathMonitor?
    private var fallbackTimer: Timer?
    private var hasWifi = false
    private var usesPeerToPeer = false
    private var channel: SecureChannel?
    private var counter: UInt64 = 0

    private let fallbackDelay = 3.0

    func start() {
        guard wifiMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.wifiChanged(path.status == .satisfied)
        }
        monitor.start(queue: .main)
        wifiMonitor = monitor
    }

    func stop() {
        wifiMonitor?.cancel()
        wifiMonitor = nil
        stopBrowsing()
        onHostChange?(nil)
    }

    // The counter starts from the clock so it keeps growing across launches,
    // which is what the Mac checks to reject replayed packets.
    func send(_ packet: Packet) {
        guard let connection, connection.state == .ready, let channel else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        counter = max(counter + 1, now)
        guard let data = channel.seal(packet, counter: counter) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    // Peer-to-peer Wi-Fi (AWDL) makes the radio hop between channels and adds
    // tens of milliseconds of jitter, so it is used only when the Mac cannot be
    // reached through the shared network.
    private func wifiChanged(_ available: Bool) {
        guard browser == nil || available != hasWifi else { return }
        hasWifi = available
        browse(peerToPeer: !available)
    }

    private func browse(peerToPeer: Bool) {
        stopBrowsing()
        usesPeerToPeer = peerToPeer
        let parameters = NWParameters()
        parameters.includePeerToPeer = peerToPeer
        let browser = NWBrowser(for: .bonjour(type: BonjourService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser.start(queue: .main)
        self.browser = browser
        if !peerToPeer {
            scheduleFallback()
        }
    }

    private func stopBrowsing() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    private func scheduleFallback() {
        fallbackTimer?.invalidate()
        let timer = Timer(timeInterval: fallbackDelay, repeats: false) { [weak self] _ in
            guard let self, self.connection == nil, !self.usesPeerToPeer else { return }
            self.browse(peerToPeer: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        if let connection, results.contains(where: { $0.endpoint == connection.endpoint }) { return }
        connection?.cancel()
        connection = nil
        let paired = results.map(\.endpoint).filter {
            if case let .service(name, _, _, _) = $0 { return name == pairing?.hostName }
            return false
        }
        guard let endpoint = paired.first else {
            onHostChange?(nil)
            if !usesPeerToPeer {
                scheduleFallback()
            }
            return
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        connect(to: endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = usesPeerToPeer
        parameters.serviceClass = .interactiveVoice
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            if case .failed = state {
                connection.cancel()
                self.connection = nil
                self.update(self.browser?.browseResults ?? [])
            }
        }
        connection.start(queue: .main)
        self.connection = connection
        if case let .service(name, _, _, _) = endpoint {
            onHostChange?(name)
        }
    }
}
