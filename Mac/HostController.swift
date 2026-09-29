import AppKit
import CryptoKit
import Network
import Observation
import ServiceManagement

@Observable
final class HostController {
    private(set) var isClientActive = false
    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var pairing: Pairing
    // Changes each time a phone connects, so the pairing window knows to close.
    private(set) var connections = 0
    // Shown in the pairing window for typing on the phone; nil while the
    // window is closed or after too many wrong tries.
    private(set) var pairingCode: String?
    let needsPairing: Bool
    var syncsClipboard = UserDefaults.standard.object(forKey: HostController.clipboardKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncsClipboard, forKey: Self.clipboardKey) }
    }
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

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
    @ObservationIgnored private var wrongCodes = 0
    @ObservationIgnored private var lastHeartbeatAt: TimeInterval = 0
    @ObservationIgnored private var frontApp: FrontApp?
    @ObservationIgnored private var frontAppSentAt: TimeInterval = 0
    // Keeps macOS from napping the companion in the background, which would
    // delay its timers: the heartbeat, and the cursor smoothing.
    @ObservationIgnored private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "Moving the cursor for Phone Mouse"
    )
    @ObservationIgnored private var clipListener: NWListener?
    @ObservationIgnored private var clipStream: ClipboardStream?
    @ObservationIgnored private var clipPending: [ClipboardStream] = []
    @ObservationIgnored private var pasteboardCount = NSPasteboard.general.changeCount
    // While ⌘C takes the selection for the phone, the clipboard is not synced.
    @ObservationIgnored private var copyingSelection = false

    private struct Offer {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let macNonces = (0..<CodePairing.rounds).map { _ in CodePairing.newNonce() }
        let phoneKey: Data
        let connection: NWConnection
        let code: String
        var commitments: [Data] = []
        var revealed = 0

        var macKey: Data { privateKey.publicKey.rawRepresentation }
        var isDone: Bool { revealed == CodePairing.rounds }

        func macCommitment(_ round: Int) -> Data {
            CodePairing.commitment(nonce: macNonces[round], ownKey: macKey, otherKey: phoneKey, round: round, code: code)
        }
    }

    private let driver = CursorDriver()
    private let keyboard = KeyboardDriver()
    private let switcher = AppSwitcher()
    // Listing apps asks browsers for their tabs and waits for them, so it
    // runs away from the cursor, in order with the commands.
    private let switcherQueue = DispatchQueue(label: "PhoneMouse.apps")
    private let finder = PointerFinder()
    private let streamer = ScreenStreamer()
    private let selection = SelectionReader()
    private let unlocker = ScreenUnlocker()
    private let silenceTimeout = 0.5
    private let pendingLimit = 4
    private let offerLimit = 8
    private let heartbeatInterval = 0.3
    private let wrongCodeLimit = 5
    private let keyWindow: Int32 = 1000
    private static let counterKey = "lastCounter"
    private static let clipboardKey = "syncsClipboard"

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
        enableLoginOnce()
        streamer.send = { [weak self] jpeg, done in
            guard let stream = self?.clipStream else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done)
                return
            }
            stream.send(.screenFrame(jpeg), completion: done)
        }
        selection.send = { [weak self] in self?.clipStream?.send(.selection($0)) }
        startListener()
        startClipboardListener()
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

    // Pairing by code is only open while the pairing window is, and every
    // opening brings a new code.
    func beginCodePairing() {
        wrongCodes = 0
        offers = offers.filter { $0.value.isDone }
        pairingCode = CodePairing.newCode()
    }

    // A finished offer stays, so the phone still gets its confirmation if the
    // first one was lost.
    func endCodePairing() {
        pairingCode = nil
        offers = offers.filter { $0.value.isDone }
    }

    private func adopt(_ pairing: Pairing) {
        self.pairing = pairing
        PairingStore.save(pairing)
        channel = SecureChannel(key: pairing.key)
        clipStream?.close()
        clipPending.forEach { $0.close() }
    }

    // Installed in Applications, the companion opens at login unless the
    // user turned that off; it is useless when it is not running.
    private func enableLoginOnce() {
        let key = "loginItemOffered"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setOpensAtLogin(true)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
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

    // The clipboard has its own TCP listener; its port reaches the phone in
    // the heartbeat.
    private func startClipboardListener() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] in self?.acceptClipboard($0) }
        listener.start(queue: .main)
        clipListener = listener
    }

    private func acceptClipboard(_ connection: NWConnection) {
        let stream = ClipboardStream(connection: connection, channel: channel, receivesFrom: .phone) { [weak self] packet in
            guard let self else { return nil }
            self.sendCounter = SecureChannel.counter(after: self.sendCounter)
            return self.channel.seal(packet, counter: self.sendCounter, from: .mac)
        }
        stream.onPacket = { [weak self, weak stream] packet in
            guard let self, let stream else { return }
            if stream !== self.clipStream {
                self.clipPending.removeAll { $0 === stream }
                self.clipStream?.close()
                self.clipStream = stream
            }
            if case let .clipboard(item) = packet {
                self.paste(item)
            } else {
                self.control(packet)
            }
        }
        stream.onClose = { [weak self, weak stream] in
            guard let self else { return }
            self.clipPending.removeAll { $0 === stream }
            if self.clipStream === stream {
                self.clipStream = nil
                self.streamer.stop()
                self.selection.stop()
            }
        }
        clipPending.append(stream)
        if clipPending.count > pendingLimit {
            clipPending.removeFirst().close()
        }
    }

    // Requests from the remote's Apps and Screen pages. They may come over
    // either connection; answers with icons or frames go over TCP.
    private func control(_ packet: Packet) {
        switch packet {
        case .appsRequest:
            sendApps()
        case let .appCommand(command):
            switcherQueue.async { [switcher] in switcher.perform(command) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.sendApps() }
        case let .screen(width):
            streamer.request(width: Int(width))
        case let .pointAt(x, y, click):
            let bounds = CGDisplayBounds(CGMainDisplayID())
            let point = CGPoint(x: bounds.minX + CGFloat(x) * bounds.width, y: bounds.minY + CGFloat(y) * bounds.height)
            driver.jump(to: point, click: click)
        case let .selectionWatch(on):
            selection.request(on)
        case .copySelection:
            copySelection()
        case let .unlock(password):
            unlocker.unlock(password: password, keyboard: keyboard) { [weak self] outcome in
                self?.reply(.unlockResult(outcome))
            }
        default:
            break
        }
    }

    // Over TCP when it is up, otherwise as a datagram.
    private func reply(_ packet: Packet) {
        if let clipStream {
            clipStream.send(packet)
        } else if let connection {
            send(packet, on: connection)
        }
    }

    private func sendApps() {
        switcherQueue.async { [weak self, switcher] in
            let apps = switcher.apps()
            DispatchQueue.main.async { self?.clipStream?.send(.apps(apps)) }
        }
    }

    private func paste(_ item: ClipboardItem) {
        guard syncsClipboard else { return }
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .text:
            board.setString(String(decoding: item.data, as: UTF8.self), forType: .string)
        case .png:
            board.setData(item.data, forType: .png)
            if let image = NSImage(data: item.data), let tiff = image.tiffRepresentation {
                board.setData(tiff, forType: .tiff)
            }
        }
        pasteboardCount = board.changeCount
    }

    // For apps that keep their selection from the accessibility API: ⌘C,
    // then the clipboard as it was before.
    private func copySelection() {
        guard !copyingSelection, let c = KeyMap.lookup("c")?.code else { return }
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let before = board.changeCount
        copyingSelection = true
        keyboard.apply(KeyEvent(seq: 0, kind: .stroke, keyCode: c, modifiers: .command))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            var text = ""
            if board.changeCount != before {
                text = board.string(forType: .string) ?? ""
                board.clearContents()
                board.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs {
                        item.setData(data, forType: type)
                    }
                    return item
                })
            }
            self.pasteboardCount = board.changeCount
            self.copyingSelection = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.clipStream?.send(.selection(String(trimmed.prefix(SelectionReader.lengthLimit))))
            }
        }
    }

    // Whatever is copied on the Mac goes to the phone: an image if there is
    // one, otherwise text.
    private func checkPasteboard() {
        let board = NSPasteboard.general
        guard !copyingSelection, board.changeCount != pasteboardCount else { return }
        guard syncsClipboard else {
            pasteboardCount = board.changeCount
            return
        }
        guard let clipStream else { return }
        pasteboardCount = board.changeCount
        if let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           png.count <= ClipboardItem.sizeLimit {
            clipStream.send(.clipboard(ClipboardItem(kind: .png, data: png)))
        } else if let text = board.string(forType: .string) {
            clipStream.send(.clipboard(ClipboardItem(kind: .text, data: Data(text.utf8.prefix(ClipboardItem.sizeLimit)))))
        }
    }

    // The phone shows what is open on the Mac. The window title needs the
    // accessibility permission the companion has anyway. Sent on a change,
    // and again now and then in case it got lost.
    private func reportFrontApp() {
        guard let connection, let app = NSWorkspace.shared.frontmostApplication else { return }
        let current = FrontApp(
            bundleID: app.bundleIdentifier ?? "",
            name: app.localizedName ?? "",
            title: windowTitle(of: app.processIdentifier) ?? ""
        )
        let now = ProcessInfo.processInfo.systemUptime
        guard current != frontApp || now - frontAppSentAt > 2 else { return }
        frontApp = current
        frontAppSentAt = now
        send(.frontApp(current), on: connection)
    }

    private func windowTitle(of pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
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
            case let .ping(id): send(.pong(id), on: connection)
            default: control(packet)
            }
            return
        }
        switch Packet(data: data) {
        case let .pairHello(phoneKey): offer(to: connection, phoneKey: phoneKey)
        case let .pairCommit(round, commitment): commit(Int(round), commitment, from: connection)
        case let .pairReveal(round, nonce): reveal(Int(round), nonce, from: connection)
        default: break
        }
    }

    private func offer(to connection: NWConnection, phoneKey: Data) {
        guard let code = pairingCode, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey)) != nil else { return }
        let id = ObjectIdentifier(connection)
        if offers[id]?.phoneKey != phoneKey || offers[id]?.code != code {
            guard offers[id] != nil || offers.count < offerLimit else { return }
            offers[id] = Offer(phoneKey: phoneKey, connection: connection, code: code)
        }
        guard let offer = offers[id] else { return }
        reply(.pairReply(publicKey: offer.macKey), on: connection)
    }

    // A commitment for a round is taken once, and only after the round before
    // has been revealed.
    private func commit(_ round: Int, _ commitment: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var offer = offers[id], round < CodePairing.rounds else { return }
        if round < offer.commitments.count {
            guard offer.commitments[round] == commitment else { return }
        } else {
            guard round == offer.commitments.count, offer.revealed == round, offer.code == pairingCode else { return }
            offer.commitments.append(commitment)
            offers[id] = offer
        }
        reply(.pairCommitReply(round: UInt8(round), offer.macCommitment(round)), on: connection)
    }

    // The Mac's nonce for a round goes out only after the phone's nonce proved
    // the phone had the right bit.
    private func reveal(_ round: Int, _ nonce: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var offer = offers[id], round < offer.commitments.count, round <= offer.revealed else { return }
        guard CodePairing.commitmentIsValid(
            offer.commitments[round],
            nonce: nonce,
            ownKey: offer.phoneKey,
            otherKey: offer.macKey,
            round: round,
            code: offer.code
        ) else {
            reply(.pairReject, on: connection)
            wrongGuess()
            return
        }
        let first = round == offer.revealed
        if first {
            offer.revealed += 1
            offers[id] = offer
        }
        reply(.pairRevealReply(round: UInt8(round), offer.macNonces[round]), on: connection)
        guard offer.isDone else { return }
        if first {
            finish(offer)
        }
        send(.ack(0), on: connection)
    }

    private func finish(_ offer: Offer) {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: offer.phoneKey),
              let secret = try? offer.privateKey.sharedSecretFromKeyAgreement(with: publicKey) else { return }
        let key = CodePairing.sessionKey(secret: secret, phoneKey: offer.phoneKey, macKey: offer.macKey)
        offers = offers.filter { $0.value.isDone }
        adopt(Pairing(hostName: Self.serviceName, keyData: key))
        pairingCode = CodePairing.newCode()
        connections += 1
    }

    // A wrong bit burns the code, and after a few the window has to be opened
    // again, which keeps guessing hopeless.
    private func wrongGuess() {
        wrongCodes += 1
        offers = offers.filter { $0.value.isDone }
        pairingCode = wrongCodes < wrongCodeLimit ? CodePairing.newCode() : nil
    }

    private func reply(_ packet: Packet, on connection: NWConnection) {
        connection.send(content: packet.encoded(), completion: .idempotent)
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
        if lastReportAt - lastHeartbeatAt > heartbeatInterval {
            heartbeat()
        }
    }

    // Tells the phone the Mac is there, and where the clipboard listens. Sent
    // as reports come in, so it does not wait on a timer.
    private func heartbeat() {
        guard let connection else { return }
        lastHeartbeatAt = ProcessInfo.processInfo.systemUptime
        send(.ack(lastKeySeq ?? 0), on: connection)
        if let port = clipListener?.port?.rawValue {
            send(.clipboardPort(port), on: connection)
        }
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
        driver.flags = keyboard.heldFlags
    }

    private func handle(_ event: VolumeEvent) {
        if let lastVolumeSeq, Int32(bitPattern: event.seq &- lastVolumeSeq) <= 0 { return }
        lastVolumeSeq = event.seq
        keyboard.apply(event)
    }

    private func handle(_ event: GestureEvent) {
        if let lastGestureSeq, Int32(bitPattern: event.seq &- lastGestureSeq) <= 0 { return }
        lastGestureSeq = event.seq
        switch event.kind {
        case .findPointer: finder.show()
        case .nextWindow: switcher.nextWindow()
        default: keyboard.apply(event)
        }
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
        if isClientActive {
            heartbeat()
            reportFrontApp()
        }
        checkPasteboard()
        guard isClientActive, ProcessInfo.processInfo.systemUptime - lastReportAt > silenceTimeout else { return }
        isClientActive = false
        driver.releaseButtons()
        keyboard.releaseAll()
        driver.flags = []
    }
}
