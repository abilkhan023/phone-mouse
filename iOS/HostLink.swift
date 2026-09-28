import Foundation
import Network

final class HostLink {
    enum Route: String {
        case wifi = "Wi-Fi"
        case direct = "Wi-Fi direct"
        case cable = "Cable"
    }

    var onHostChange: ((String?) -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onHostsChange: (([String]) -> Void)?
    var onRouteChange: ((Route?) -> Void)?
    enum Preference: String, CaseIterable {
        case automatic
        case cable
        case wifi
    }

    // Which way to reach the Mac. Automatic tries a cable first when one is
    // plugged in, since it is faster and steadier than Wi-Fi.
    var preference = Preference.automatic {
        didSet {
            guard preference != oldValue else { return }
            reconnect()
        }
    }
    // Paired Macs, the preferred one first. The link connects to the first
    // of them in sight.
    var pairings: [Pairing] = [] {
        didSet {
            guard pairings != oldValue, wifiMonitor != nil else { return }
            update(browser?.browseResults ?? [])
        }
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var wifiMonitor: NWPathMonitor?
    private var fallbackTimer: Timer?
    private var hasWifi = false
    private var usesPeerToPeer = false
    private var channel: SecureChannel?
    private var connectedName: String?
    private var counter: UInt64 = 0
    private var macCounter: UInt64 = 0
    private var clipStream: ClipboardStream?
    private var interfaceMonitor: NWPathMonitor?
    private var hasCable = false
    private var cableFailedUntil: TimeInterval = 0
    private var cableCheck: Timer?
    private var heardFromMac = false
    private let cableTimeout = 2.5
    private let cableRetry = 30.0

    private let fallbackDelay = 3.0

    func start() {
        guard wifiMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.wifiChanged(path.status == .satisfied)
        }
        monitor.start(queue: .main)
        wifiMonitor = monitor
        let interfaces = NWPathMonitor()
        interfaces.pathUpdateHandler = { [weak self] path in
            self?.cableChanged(path.availableInterfaces.contains(where: Self.isCable))
        }
        interfaces.start(queue: .main)
        interfaceMonitor = interfaces
    }

    private static func isCable(_ interface: NWInterface) -> Bool {
        if interface.type == .wiredEthernet { return true }
        guard interface.type == .other else { return false }
        return !["awdl", "llw", "utun", "ipsec", "lo", "pdp", "ap"].contains { interface.name.hasPrefix($0) }
    }

    private func cableChanged(_ available: Bool) {
        guard available != hasCable else { return }
        hasCable = available
        if available {
            cableFailedUntil = 0
        }
        if preference == .automatic {
            reconnect()
        }
    }

    private func reconnect() {
        guard wifiMonitor != nil else { return }
        disconnect()
        update(browser?.browseResults ?? [])
    }

    func stop() {
        wifiMonitor?.cancel()
        wifiMonitor = nil
        interfaceMonitor?.cancel()
        interfaceMonitor = nil
        hasCable = false
        stopBrowsing()
        onHostChange?(nil)
    }

    // The counter starts from the clock so it keeps growing across launches,
    // which is what the Mac checks to reject replayed packets.
    func send(_ packet: Packet) {
        guard let connection, connection.state == .ready, let data = seal(packet) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    // Returns false while there is no clipboard connection yet.
    @discardableResult
    func sendClipboard(_ item: ClipboardItem) -> Bool {
        guard let clipStream else { return false }
        clipStream.send(.clipboard(item))
        return true
    }

    // Over TCP when that connection is up, so the answer can come back the
    // same way; otherwise as a datagram.
    func sendReliably(_ packet: Packet) {
        if let clipStream {
            clipStream.send(packet)
        } else {
            send(packet)
        }
    }

    private func seal(_ packet: Packet) -> Data? {
        guard let channel else { return nil }
        counter = SecureChannel.counter(after: counter)
        return channel.seal(packet, counter: counter, from: .phone)
    }

    // Macs the phone can see, for pairing by code.
    func host(named name: String) -> NWEndpoint? {
        browser?.browseResults.map(\.endpoint).first { Self.name(of: $0) == name }
    }

    private static func name(of endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }

    static func parameters(peerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = peerToPeer
        parameters.serviceClass = .interactiveVoice
        return parameters
    }

    var usesPeerToPeerNow: Bool { usesPeerToPeer }

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
        disconnect()
    }

    private func disconnect() {
        cableCheck?.invalidate()
        cableCheck = nil
        connection?.cancel()
        connection = nil
        connectedName = nil
        channel = nil
        clipStream?.close()
        clipStream = nil
        onRouteChange?(nil)
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
        let names = results.compactMap { Self.name(of: $0.endpoint) }
        onHostsChange?(names.sorted())
        let target = pairings.first { names.contains($0.hostName) }
        if let connection, let target, target.hostName == connectedName,
           results.contains(where: { $0.endpoint == connection.endpoint }) { return }
        disconnect()
        guard let target, let endpoint = results.map(\.endpoint).first(where: { Self.name(of: $0) == target.hostName }) else {
            onHostChange?(nil)
            if !usesPeerToPeer {
                scheduleFallback()
            }
            return
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        channel = SecureChannel(key: target.key)
        connectedName = target.hostName
        connect(to: endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        macCounter = 0
        heardFromMac = false
        let parameters = Self.parameters(peerToPeer: usesPeerToPeer)
        let now = ProcessInfo.processInfo.systemUptime
        let triesCable = preference == .cable || (preference == .automatic && hasCable && now > cableFailedUntil)
        if triesCable {
            parameters.prohibitedInterfaceTypes = [.wifi, .cellular]
        } else if preference == .wifi {
            parameters.prohibitedInterfaceTypes = [.wiredEthernet]
        }
        if triesCable, preference == .automatic {
            watchCable()
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .failed:
                self.disconnect()
                self.update(self.browser?.browseResults ?? [])
            case .ready:
                self.onRouteChange?(Self.route(of: connection))
            default:
                break
            }
        }
        connection.pathUpdateHandler = { [weak self, weak connection] _ in
            guard let self, let connection, connection === self.connection else { return }
            self.onRouteChange?(Self.route(of: connection))
        }
        connection.start(queue: .main)
        self.connection = connection
        receive(on: connection)
        if case let .service(name, _, _, _) = endpoint {
            onHostChange?(name)
        }
    }

    // If the Mac does not answer over the cable soon, the cable is not a way
    // to it after all, and the link goes back to Wi-Fi for a while.
    private func watchCable() {
        let timer = Timer(timeInterval: cableTimeout, repeats: false) { [weak self] _ in
            guard let self, !self.heardFromMac else { return }
            self.cableFailedUntil = ProcessInfo.processInfo.systemUptime + self.cableRetry
            self.reconnect()
        }
        RunLoop.main.add(timer, forMode: .common)
        cableCheck = timer
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, connection === self.connection else { return }
            if let data, let channel = self.channel,
               let (packet, counter) = channel.open(data, from: .mac), counter > self.macCounter {
                self.macCounter = counter
                self.heardFromMac = true
                if case let .clipboardPort(port) = packet {
                    self.openClipboard(port: port)
                } else {
                    self.onPacket?(packet)
                }
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private static func route(of connection: NWConnection) -> Route? {
        guard let path = connection.currentPath else { return nil }
        if let interface = path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) }),
           interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw") {
            return .direct
        }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) || path.usesInterfaceType(.other) { return .cable }
        return .wifi
    }

    // The clipboard goes over TCP to the same Mac, on the port it announced.
    private func openClipboard(port: UInt16) {
        guard clipStream == nil, let connection, let channel,
              case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
              let port = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = usesPeerToPeer
        let tcp = NWConnection(host: host, port: port, using: parameters)
        let stream = ClipboardStream(connection: tcp, channel: channel, receivesFrom: .mac) { [weak self] in self?.seal($0) }
        stream.onPacket = { [weak self] in self?.onPacket?($0) }
        stream.onClose = { [weak self, weak stream] in
            if self?.clipStream === stream {
                self?.clipStream = nil
            }
        }
        clipStream = stream
        stream.send(.ping(0))
    }
}
