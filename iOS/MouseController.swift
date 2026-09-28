import CoreMotion
import Observation
import UIKit

enum PointerMode: String, CaseIterable {
    case air
    case desk
    case touchpad
    case remote

    var title: String {
        switch self {
        case .air: "In air"
        case .desk: "On desk"
        case .touchpad: "Touchpad"
        case .remote: "Remote"
        }
    }

    var symbol: String {
        switch self {
        case .air: "scope"
        case .desk: "computermouse"
        case .touchpad: "rectangle.and.hand.point.up.left"
        case .remote: "av.remote"
        }
    }

    var hint: String {
        switch self {
        case .air: "Hold the phone and point it at the screen."
        case .desk: "Slide the phone across the desk like a mouse."
        case .touchpad: "Drag to move, tap to click, two fingers to scroll."
        case .remote: ""
        }
    }
}

enum RemoteTab: String, CaseIterable {
    case media
    case slides
    case apps
    case screen
    case actions

    var title: String {
        switch self {
        case .media: "Media"
        case .slides: "Slides"
        case .apps: "Apps"
        case .screen: "Screen"
        case .actions: "Actions"
        }
    }
}

@Observable
final class MouseController {
    enum CodeState: Equatable {
        case idle
        case entering(String)
        case waiting(String)
        case failed(String, message: String)
    }

    private(set) var hostName: String?
    // True while the Mac answers, which only a Mac holding the same key can.
    private(set) var isLinked = false
    private(set) var mode: PointerMode
    private(set) var typed: String
    // Paired Macs, the preferred one first.
    private(set) var pairings: [Pairing]
    private(set) var route: HostLink.Route?
    // Half the round trip to the Mac, in milliseconds.
    private(set) var latency: Double?
    private(set) var notice: String?
    // What is open on the Mac right now.
    private(set) var frontApp: FrontApp?
    private(set) var apps: [RunningApp] = []
    private(set) var screenImage: UIImage?
    var remoteTab: RemoteTab {
        didSet { UserDefaults.standard.set(remoteTab.rawValue, forKey: Self.remoteKey) }
    }
    let settings = Settings()
    let dictation = Dictation()
    // Latched by a tap, for the next key only.
    private(set) var modifiers: KeyModifiers = []
    // Held down by a finger on the key, and down on the Mac too.
    private(set) var held: KeyModifiers = []
    private(set) var nearbyHosts: [String] = []
    private(set) var codeState = CodeState.idle
    // Changes when the typed line is erased, so the key capture starts over.
    private(set) var lineResets = 0
    var isTyping = false
    var isPairing = false

    @ObservationIgnored private var fallbackTimer: Timer?
    @ObservationIgnored private var seq: UInt32 = 0
    // Key numbers start at random on each launch, so the Mac can tell a new
    // stream from repeats of the old one.
    @ObservationIgnored private var keySeq: UInt32
    @ObservationIgnored private let keyStreamStart: UInt32
    @ObservationIgnored private var unsentKeys: [KeyEvent] = []
    @ObservationIgnored private var lastMacAt: TimeInterval = 0
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var codeClient: CodePairingClient?
    @ObservationIgnored private var heldSince: [UInt8: TimeInterval] = [:]
    @ObservationIgnored private var usedWhileHeld = false
    @ObservationIgnored private var volumeSeq: UInt32 = 0
    @ObservationIgnored private var gestureSeq: UInt32 = 0
    @ObservationIgnored private var buttons: MouseButtons = []
    @ObservationIgnored private var pendingMove = CGSize.zero
    @ObservationIgnored private var pendingScroll = CGSize.zero
    @ObservationIgnored private var frozenUntil: TimeInterval = 0
    @ObservationIgnored private var lastSampleAt: TimeInterval = 0
    @ObservationIgnored private var lastTouchAt: TimeInterval = 0
    @ObservationIgnored private var desk = DeskTracker()
    @ObservationIgnored private var air = AirPointer()
    @ObservationIgnored private var touchScrolling = false
    // What dictation has typed on the Mac in this session.
    @ObservationIgnored private var dictated = ""
    @ObservationIgnored private var screenTimer: Timer?
    @ObservationIgnored private var shakes: [TimeInterval] = []
    @ObservationIgnored private var lastShakeAt: TimeInterval = 0
    @ObservationIgnored private var laserHeld = false
    @ObservationIgnored private var pingID: UInt32 = 0
    @ObservationIgnored private var pingSentAt: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var noticeTimer: Timer?

    private static let modeKey = "pointerMode"
    private static let typedKey = "typedText"
    private static let remoteKey = "remoteTab"

    private let motion = CMMotionManager()
    private let link = HostLink()
    let volumeKeys = VolumeKeys()
    private let haptics = UIImpactFeedbackGenerator(style: .rigid)
    private let rate = 100.0
    private let deskGain = 18000.0
    private let deskBoostSpeed = 0.08
    private let deskBoostLimit = 3.0
    private let touchGain = 1.2
    private let touchBoostSpeed = 400.0
    private let touchBoostLimit = 3.0
    private let scrollGain = 1.5
    private let freezeDuration = 0.12
    private let clickDuration = 0.04
    private let keyRepeats = 3
    private let keyRepeatGap = 0.01
    private let typedLimit = 2000
    private let linkTimeout = 2.5
    private let resendTicks = 5
    private let resendBatch = 32
    private let tapLimit = 0.3
    private let pingTicks = 100
    private let shakeForce = 2.2
    private let shakeWindow = 0.8
    private let shakeCount = 3
    private let shakeGap = 0.08
    private let latencyWeight = 0.3

    init() {
        mode = PointerMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .air
        let keyStart = UInt32.random(in: .min ... .max)
        keySeq = keyStart
        keyStreamStart = keyStart &+ 1
        typed = UserDefaults.standard.string(forKey: Self.typedKey) ?? ""
        remoteTab = RemoteTab(rawValue: UserDefaults.standard.string(forKey: Self.remoteKey) ?? "") ?? .media
        pairings = PairingStore.loadAll()
        isPairing = pairings.isEmpty
        link.pairings = pairings
        link.preference = settings.connection
        settings.onConnectionChange = { [weak self] in self?.link.preference = $0 }
        link.onHostChange = { [weak self] in
            self?.hostName = $0
            self?.latency = nil
        }
        link.onHostsChange = { [weak self] in self?.nearbyHosts = $0 }
        link.onRouteChange = { [weak self] in self?.route = $0 }
        link.onPacket = { [weak self] in self?.received($0) }
        volumeKeys.onPress = { [weak self] in self?.changeVolume($0) }
        dictation.onText = { [weak self] in self?.dictate($0) }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        link.start()
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / rate
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                self?.send(motion: data)
            }
        } else {
            let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
                self?.send(motion: nil)
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        buttons = []
        send(motion: nil)
        releaseAllModifiers()
        dictation.stop()
        screenTimer?.invalidate()
        screenTimer = nil
        screenImage = nil
        link.stop()
        setLinked(false)
        cancelCodePairing()
        UserDefaults.standard.set(typed, forKey: Self.typedKey)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // A new pairing becomes the preferred Mac; others stay for switching.
    func pair(with pairing: Pairing) {
        savePairings([pairing] + pairings.filter { $0.hostName != pairing.hostName })
        isPairing = false
        cancelCodePairing()
    }

    func prefer(_ name: String) {
        guard let chosen = pairings.first(where: { $0.hostName == name }) else { return }
        savePairings([chosen] + pairings.filter { $0.hostName != name })
    }

    func forget(_ name: String) {
        savePairings(pairings.filter { $0.hostName != name })
        if pairings.isEmpty {
            showPairing()
        }
    }

    private func savePairings(_ list: [Pairing]) {
        pairings = list
        PairingStore.saveAll(list)
        link.pairings = list
    }

    // Laser pointer for slides: the phone steers the cursor like in the air
    // while the finger holds the button.
    func setLaser(_ held: Bool) {
        laserHeld = held
        air.reset()
        haptics.impactOccurred(intensity: held ? 0.8 : 0.4)
    }

    func setTouchScrolling(_ scrolling: Bool) {
        touchScrolling = scrolling
    }

    // Phone to Mac goes through the system paste button, which reads the
    // clipboard without asking each time.
    func sendClipboard(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: UIImage.self) {
            _ = provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let data = (object as? UIImage)?.pngData() else { return }
                DispatchQueue.main.async { self?.deliver(ClipboardItem(kind: .png, data: data)) }
            }
        } else {
            _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                guard let text else { return }
                DispatchQueue.main.async { self?.deliver(ClipboardItem(kind: .text, data: Data(text.utf8))) }
            }
        }
    }

    private func deliver(_ item: ClipboardItem) {
        guard item.data.count <= ClipboardItem.sizeLimit else {
            show("Too large to send")
            return
        }
        show(link.sendClipboard(item) ? "Sent to the Mac clipboard" : "Not connected to a Mac yet")
    }

    func requestApps() {
        link.sendReliably(.appsRequest)
    }

    func perform(_ command: AppCommand) {
        link.sendReliably(.appCommand(command))
        haptics.impactOccurred(intensity: 0.6)
    }

    // Frames come while the mini screen is on view; the request is repeated
    // so the Mac stops by itself if the phone goes away.
    // Width is the picture's width on the phone in pixels, zero to stop.
    func watchScreen(width: Int) {
        screenTimer?.invalidate()
        screenTimer = nil
        let width = UInt16(clamping: width)
        link.sendReliably(.screen(width: width))
        guard width > 0 else {
            screenImage = nil
            return
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.link.sendReliably(.screen(width: width)) }
        RunLoop.main.add(timer, forMode: .common)
        screenTimer = timer
    }

    func point(atX x: Double, y: Double, click: Bool) {
        link.sendReliably(.pointAt(x: Float(x), y: Float(y), click: click))
        if click {
            haptics.impactOccurred(intensity: 0.8)
        }
    }

    // Double tap and drag on the touchpad holds the button down while the
    // finger moves.
    func setDragging(_ dragging: Bool) {
        setButton(.left, pressed: dragging)
    }

    func announce(_ text: String) {
        show(text)
    }

    private func show(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in self?.notice = nil }
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
    }

    private func receiveClipboard(_ item: ClipboardItem) {
        switch item.kind {
        case .text:
            UIPasteboard.general.string = String(decoding: item.data, as: UTF8.self)
        case .png:
            guard let image = UIImage(data: item.data) else { return }
            UIPasteboard.general.image = image
        }
        show(item.kind == .png ? "Image copied from the Mac" : "Text copied from the Mac")
    }

    // The pairing screen covers the touchpad, so its keyboard goes away.
    func showPairing() {
        isTyping = false
        dictation.stop()
        releaseAllModifiers()
        isPairing = true
    }

    func choose(_ name: String) {
        cancelCodePairing()
        codeState = .entering(name)
    }

    func pairByCode(with name: String, code: String) {
        codeClient?.cancel()
        guard let host = link.host(named: name) else {
            codeState = .failed(name, message: "\(name) is no longer in sight.")
            return
        }
        codeState = .waiting(name)
        codeClient = CodePairingClient(host: host, code: code, peerToPeer: link.usesPeerToPeerNow) { [weak self] result in
            guard let self else { return }
            self.codeClient = nil
            switch result {
            case let .success(pairing):
                self.pair(with: pairing)
            case .failure(.noAnswer):
                self.codeState = .failed(name, message: "\(name) did not answer. Open Pair iPhone on the Mac.")
            case .failure(.wrongCode):
                self.codeState = .failed(name, message: "Wrong code. The Mac now shows a new one.")
            case .failure(.mismatch):
                self.codeState = .failed(name, message: "Could not verify \(name). Close the pairing window on the Mac, open it again and type the new code.")
            }
        }
    }

    func cancelCodePairing() {
        codeClient?.cancel()
        codeClient = nil
        codeState = .idle
    }

    func select(_ mode: PointerMode) {
        self.mode = mode
        isTyping = false
        desk.reset()
        air.reset()
        pendingMove = .zero
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
    }

    func setButton(_ button: MouseButtons, pressed: Bool) {
        if pressed {
            buttons.insert(button)
            if mode == .air {
                let undo = air.rewind()
                pendingMove.width += undo.x
                pendingMove.height += undo.y
            }
        } else {
            buttons.remove(button)
        }
        freeze()
        haptics.impactOccurred(intensity: pressed ? 1 : 0.5)
        send(motion: nil)
    }

    // The on-screen buttons by where they sit; left-handed use swaps them.
    func setPad(left: Bool, pressed: Bool) {
        setButton(left != settings.leftHanded ? .left : .right, pressed: pressed)
    }

    func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
        } else {
            dictated = ""
            dictation.start(language: settings.dictationLanguage)
        }
        haptics.impactOccurred(intensity: 0.7)
    }

    // Typed on the Mac as it is heard. When the recognizer revises its last
    // words, the changed tail is erased and typed again.
    private func dictate(_ full: String) {
        let old = Array(dictated)
        let new = Array(full)
        var common = 0
        while common < old.count, common < new.count, old[common] == new[common] {
            common += 1
        }
        let erase = old.count - common
        if erase > 0 {
            typed = String(typed.dropLast(erase))
            queue(KeyEvent(seq: 0, kind: .backspace, text: String(erase)))
        }
        if common < new.count {
            let added = String(new[common...])
            typed = String((typed + added).suffix(typedLimit))
            queue(KeyEvent(seq: 0, kind: .text, text: added))
        }
        dictated = full
    }

    func click(_ button: MouseButtons) {
        setButton(button, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + clickDuration) { [weak self] in
            self?.setButton(button, pressed: false)
        }
    }

    func toggle(_ modifier: KeyModifiers) {
        modifiers.formSymmetricDifference(modifier)
        haptics.impactOccurred(intensity: 0.5)
    }

    // A modifier goes down on the Mac as soon as the finger lands, so it can
    // be held through several keys or a click, like on a real keyboard. A
    // short tap with nothing pressed meanwhile latches it for the next key.
    func holdModifier(_ modifier: KeyModifiers) {
        guard !held.contains(modifier) else { return }
        if held.isEmpty {
            usedWhileHeld = false
        }
        held.insert(modifier)
        heldSince[modifier.rawValue] = ProcessInfo.processInfo.systemUptime
        queue(KeyEvent(seq: 0, kind: .hold, modifiers: modifier))
        haptics.impactOccurred(intensity: 0.5)
    }

    func releaseModifier(_ modifier: KeyModifiers) {
        guard held.contains(modifier) else { return }
        held.remove(modifier)
        queue(KeyEvent(seq: 0, kind: .release, modifiers: modifier))
        let since = heldSince.removeValue(forKey: modifier.rawValue) ?? 0
        if !usedWhileHeld, ProcessInfo.processInfo.systemUptime - since < tapLimit {
            modifiers.formSymmetricDifference(modifier)
        }
    }

    private func releaseAllModifiers() {
        for modifier in [KeyModifiers.control, .option, .command, .shift] where held.contains(modifier) {
            held.remove(modifier)
            queue(KeyEvent(seq: 0, kind: .release, modifiers: modifier))
        }
        heldSince = [:]
        modifiers = []
    }

    // Keys of the Mac keyboard that iOS has no key for. Modifiers stay latched
    // until the next key, the way sticky keys work.
    func press(_ keyCode: UInt8) {
        usedWhileHeld = true
        queue(KeyEvent(seq: 0, kind: .stroke, keyCode: keyCode, modifiers: modifiers))
        modifiers = []
        haptics.impactOccurred(intensity: 0.5)
    }

    func type(_ kind: KeyEvent.Kind, text: String) {
        if !modifiers.union(held).subtracting(.function).isEmpty, let key = strokeKey(kind, text: text) {
            if key.shift { modifiers.insert(.shift) }
            press(key.code)
            return
        }
        modifiers = []
        switch kind {
        case .text: typed = String((typed + text).suffix(typedLimit))
        case .backspace: typed = String(typed.dropLast())
        case .enter: typed = String((typed + "\n").suffix(typedLimit))
        case .stroke, .hold, .release: break
        }
        queue(KeyEvent(seq: 0, kind: kind, text: text))
    }

    // Erasing the line erases the same text on the Mac, in one event.
    func clearTyped() {
        guard !typed.isEmpty else { return }
        queue(KeyEvent(seq: 0, kind: .backspace, text: String(typed.count)))
        typed = ""
        lineResets += 1
        UserDefaults.standard.set(typed, forKey: Self.typedKey)
        haptics.impactOccurred(intensity: 0.7)
    }

    // Key events wait in order until the Mac confirms them, so nothing typed
    // is lost when the connection drops; they go out again once it is back.
    private func queue(_ event: KeyEvent) {
        var event = event
        keySeq &+= 1
        event.seq = keySeq
        unsentKeys.append(event)
        link.send(.key(event))
    }

    private func resendKeys() {
        for event in unsentKeys.prefix(resendBatch) {
            link.send(.key(event))
        }
    }

    // Anything sealed by the Mac shows it is there.
    private func received(_ packet: Packet) {
        lastMacAt = ProcessInfo.processInfo.systemUptime
        setLinked(true)
        switch packet {
        case let .clipboard(item):
            receiveClipboard(item)
            return
        case let .frontApp(app):
            let switched = app.bundleID != frontApp?.bundleID
            frontApp = app
            if switched, mode == .remote, [.media, .slides].contains(remoteTab), let tab = Self.remoteTab(for: app) {
                remoteTab = tab
            }
            if switched, mode == .remote, remoteTab == .apps {
                requestApps()
            }
            return
        case let .apps(list):
            apps = list
            return
        case let .screenFrame(jpeg):
            if screenTimer != nil {
                screenImage = UIImage(data: jpeg)
            }
            return
        case let .pong(id):
            guard let sentAt = pingSentAt.removeValue(forKey: id) else { return }
            let sample = (ProcessInfo.processInfo.systemUptime - sentAt) * 500
            latency = latency.map { $0 + (sample - $0) * latencyWeight } ?? sample
            return
        default:
            break
        }
        guard case let .ack(seq) = packet else { return }
        // An ack from before this launch belongs to another stream of numbers.
        guard Int32(bitPattern: seq &- keyStreamStart) >= 0, Int32(bitPattern: keySeq &- seq) >= 0 else { return }
        unsentKeys.removeAll { Int32(bitPattern: seq &- $0.seq) >= 0 }
    }

    // The remote page that suits the app in front: slides for presentations,
    // media for players and for YouTube in a browser.
    private static func remoteTab(for app: FrontApp) -> RemoteTab? {
        let slides = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]
        let media = ["com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.QuickTimePlayerX",
                     "org.videolan.vlc", "com.apple.podcasts", "com.colliderli.iina", "com.yandex.music"]
        let title = app.title.lowercased()
        if slides.contains(app.bundleID) || title.contains("google slides") || title.contains("google презентации") {
            return .slides
        }
        if media.contains(app.bundleID) || title.contains("youtube") {
            return .media
        }
        return nil
    }

    private func setLinked(_ linked: Bool) {
        guard linked != isLinked else { return }
        isLinked = linked
        if !linked {
            frontApp = nil
        }
        if linked {
            volumeKeys.start()
        } else {
            volumeKeys.stop()
        }
    }

    private func strokeKey(_ kind: KeyEvent.Kind, text: String) -> (code: UInt8, shift: Bool)? {
        switch kind {
        case .backspace: (KeyMap.backspace, false)
        case .enter: (KeyMap.returnKey, false)
        case .text: text.count == 1 ? text.first.flatMap(KeyMap.lookup) : nil
        case .stroke, .hold, .release: nil
        }
    }

    func gesture(_ kind: GestureEvent.Kind) {
        gestureSeq &+= 1
        repeatSend(.gesture(GestureEvent(seq: gestureSeq, kind: kind)))
        haptics.impactOccurred(intensity: 0.7)
    }

    // In the slides remote the volume buttons turn the slides, like a
    // presenter clicker; everywhere else they set the Mac's volume.
    private func changeVolume(_ direction: VolumeEvent.Direction) {
        if mode == .remote, remoteTab == .slides {
            slide(forward: direction == .up)
            return
        }
        volumeSeq &+= 1
        repeatSend(.volume(VolumeEvent(seq: volumeSeq, direction: direction)))
    }

    private func repeatSend(_ packet: Packet) {
        for attempt in 0..<keyRepeats {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * keyRepeatGap) { [weak self] in
                self?.link.send(packet)
            }
        }
    }

    // The Mac's top row keys carry the media functions, so the remote sends
    // those: F7 to F12 without fn.
    func media(_ key: Int) {
        modifiers = []
        press(KeyMap.function[key])
    }

    func pressFunction(_ keyCode: UInt8) {
        modifiers.insert(.function)
        press(keyCode)
    }

    func slide(forward: Bool) {
        modifiers = []
        press(forward ? KeyMap.right : KeyMap.left)
    }

    func movePointer(by delta: CGSize) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(max(now - lastTouchAt, 1.0 / 240), 1.0 / 30)
        lastTouchAt = now
        let speed = hypot(delta.width, delta.height) / dt
        let gain = (touchGain + min(speed / touchBoostSpeed, touchBoostLimit)) * settings.pointerSpeed
        pendingMove.width += delta.width * gain
        pendingMove.height += delta.height * gain
    }

    func scroll(by delta: CGSize) {
        let gain = scrollGain * settings.scrollSpeed * (settings.naturalScrolling ? 1 : -1)
        pendingScroll.width += delta.width * gain
        pendingScroll.height += delta.height * gain
        freeze()
    }

    private func freeze() {
        frozenUntil = ProcessInfo.processInfo.systemUptime + freezeDuration
        desk.forgiveLift()
    }

    private func send(motion: CMDeviceMotion?) {
        ticks &+= 1
        if ticks % resendTicks == 0 {
            if !unsentKeys.isEmpty {
                resendKeys()
            }
            if isLinked, ProcessInfo.processInfo.systemUptime - lastMacAt > linkTimeout {
                setLinked(false)
                latency = nil
            }
        }
        if ticks % pingTicks == 0, isLinked {
            pingID &+= 1
            pingSentAt = pingSentAt.filter { $0.key &+ 5 > pingID }
            pingSentAt[pingID] = ProcessInfo.processInfo.systemUptime
            link.send(.ping(pingID))
        }
        if let motion {
            detectShake(motion)
        }
        var report = MouseReport(seq: seq, buttons: buttons)
        seq &+= 1
        let delta = pointerDelta(for: motion)
        report.dx = Float(delta.x + pendingMove.width)
        report.dy = Float(delta.y + pendingMove.height)
        pendingMove = .zero
        report.scrollX = Float(pendingScroll.width)
        report.scrollY = Float(pendingScroll.height)
        report.isScrolling = mode == .touchpad && touchScrolling
        pendingScroll = .zero
        link.send(.mouse(report))
    }

    private func pointerDelta(for motion: CMDeviceMotion?) -> CGPoint {
        guard let motion, mode != .touchpad else { return .zero }
        let dt = min(max(motion.timestamp - lastSampleAt, 0), 0.05)
        lastSampleAt = motion.timestamp
        let delta = motionDelta(motion, dt: dt)
        return CGPoint(x: delta.x * settings.pointerSpeed, y: delta.y * settings.pointerSpeed)
    }

    private func motionDelta(_ motion: CMDeviceMotion, dt: Double) -> CGPoint {
        let frozen = ProcessInfo.processInfo.systemUptime < frozenUntil
        switch mode {
        case .touchpad:
            return .zero
        case .remote:
            guard laserHeld else { return .zero }
            return airStep(motion, dt: dt)
        case .air:
            guard !frozen else {
                air.reset()
                return .zero
            }
            return airStep(motion, dt: dt)
        case .desk:
            guard !frozen else {
                desk.reset()
                return .zero
            }
            let shift = desk.displacement(
                acceleration: -SIMD2(motion.userAcceleration.x, motion.userAcceleration.y),
                vertical: motion.userAcceleration.z,
                rotation: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
                gravityZ: motion.gravity.z,
                time: motion.timestamp,
                dt: dt
            )
            let speed = dt > 0 ? hypot(shift.x, shift.y) / dt : 0
            let gain = deskGain * min(1 + speed / deskBoostSpeed, deskBoostLimit)
            return CGPoint(x: shift.x * gain, y: -shift.y * gain)
        }
    }

    // A few hard jolts in a row light up the cursor on the Mac. The desk
    // mode is left out, where sliding the phone is the point.
    private func detectShake(_ motion: CMDeviceMotion) {
        guard mode != .desk, isLinked else { return }
        let force = hypot(hypot(motion.userAcceleration.x, motion.userAcceleration.y), motion.userAcceleration.z)
        let now = motion.timestamp
        guard force > shakeForce, now - (shakes.last ?? 0) > shakeGap else { return }
        shakes = shakes.filter { now - $0 < shakeWindow } + [now]
        guard shakes.count >= shakeCount, now - lastShakeAt > 2 else { return }
        shakes = []
        lastShakeAt = now
        gesture(.findPointer)
    }

    private func airStep(_ motion: CMDeviceMotion, dt: Double) -> CGPoint {
        let step = air.movement(
            rotation: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
            gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
            dt: dt
        )
        return CGPoint(x: step.x, y: step.y)
    }
}
