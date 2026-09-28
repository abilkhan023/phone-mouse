import CoreMotion
import Observation
import UIKit

enum PointerMode: String, CaseIterable {
    case air
    case desk
    case touchpad

    var title: String {
        switch self {
        case .air: "In air"
        case .desk: "On desk"
        case .touchpad: "Touchpad"
        }
    }

    var hint: String {
        switch self {
        case .air: "Hold the phone and point it at the screen."
        case .desk: "Slide the phone across the desk like a mouse."
        case .touchpad: "Drag to move, tap to click, two fingers to scroll."
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
    private(set) var pairing: Pairing?
    private(set) var modifiers: KeyModifiers = []
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

    private static let modeKey = "pointerMode"
    private static let typedKey = "typedText"

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
    private let linkTimeout = 1.5
    private let resendTicks = 5
    private let resendBatch = 32

    init() {
        mode = PointerMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .air
        let keyStart = UInt32.random(in: .min ... .max)
        keySeq = keyStart
        keyStreamStart = keyStart &+ 1
        typed = UserDefaults.standard.string(forKey: Self.typedKey) ?? ""
        pairing = PairingStore.load()
        isPairing = pairing == nil
        link.pairing = pairing
        link.onHostChange = { [weak self] in self?.hostName = $0 }
        link.onHostsChange = { [weak self] in self?.nearbyHosts = $0 }
        link.onPacket = { [weak self] in self?.received($0) }
        volumeKeys.onPress = { [weak self] in self?.changeVolume($0) }
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
        link.stop()
        setLinked(false)
        cancelCodePairing()
        UserDefaults.standard.set(typed, forKey: Self.typedKey)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func pair(with pairing: Pairing) {
        PairingStore.save(pairing)
        self.pairing = pairing
        link.pairing = pairing
        isPairing = false
        cancelCodePairing()
    }

    // The pairing screen covers the touchpad, so its keyboard goes away.
    func showPairing() {
        isTyping = false
        modifiers = []
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

    // Keys of the Mac keyboard that iOS has no key for. Modifiers stay latched
    // until the next key, the way sticky keys work.
    func press(_ keyCode: UInt8) {
        queue(KeyEvent(seq: 0, kind: .stroke, keyCode: keyCode, modifiers: modifiers))
        modifiers = []
        haptics.impactOccurred(intensity: 0.5)
    }

    func type(_ kind: KeyEvent.Kind, text: String) {
        if !modifiers.subtracting(.function).isEmpty, let key = strokeKey(kind, text: text) {
            if key.shift { modifiers.insert(.shift) }
            press(key.code)
            return
        }
        modifiers = []
        switch kind {
        case .text: typed = String((typed + text).suffix(typedLimit))
        case .backspace: typed = String(typed.dropLast())
        case .enter: typed = String((typed + "\n").suffix(typedLimit))
        case .stroke: break
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

    private func received(_ packet: Packet) {
        guard case let .ack(seq) = packet else { return }
        lastMacAt = ProcessInfo.processInfo.systemUptime
        setLinked(true)
        // An ack from before this launch belongs to another stream of numbers.
        guard Int32(bitPattern: seq &- keyStreamStart) >= 0, Int32(bitPattern: keySeq &- seq) >= 0 else { return }
        unsentKeys.removeAll { Int32(bitPattern: seq &- $0.seq) >= 0 }
    }

    private func setLinked(_ linked: Bool) {
        guard linked != isLinked else { return }
        isLinked = linked
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
        case .stroke: nil
        }
    }

    func gesture(_ kind: GestureEvent.Kind) {
        gestureSeq &+= 1
        repeatSend(.gesture(GestureEvent(seq: gestureSeq, kind: kind)))
        haptics.impactOccurred(intensity: 0.7)
    }

    private func changeVolume(_ direction: VolumeEvent.Direction) {
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

    func movePointer(by delta: CGSize) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(max(now - lastTouchAt, 1.0 / 240), 1.0 / 30)
        lastTouchAt = now
        let speed = hypot(delta.width, delta.height) / dt
        let gain = touchGain + min(speed / touchBoostSpeed, touchBoostLimit)
        pendingMove.width += delta.width * gain
        pendingMove.height += delta.height * gain
    }

    func scroll(by delta: CGSize) {
        pendingScroll.width += delta.width * scrollGain
        pendingScroll.height += delta.height * scrollGain
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
            }
        }
        var report = MouseReport(seq: seq, buttons: buttons)
        seq &+= 1
        let delta = pointerDelta(for: motion)
        report.dx = Float(delta.x + pendingMove.width)
        report.dy = Float(delta.y + pendingMove.height)
        pendingMove = .zero
        report.scrollX = Float(pendingScroll.width)
        report.scrollY = Float(pendingScroll.height)
        pendingScroll = .zero
        link.send(.mouse(report))
    }

    private func pointerDelta(for motion: CMDeviceMotion?) -> CGPoint {
        guard let motion, mode != .touchpad else { return .zero }
        let dt = min(max(motion.timestamp - lastSampleAt, 0), 0.05)
        lastSampleAt = motion.timestamp
        let frozen = ProcessInfo.processInfo.systemUptime < frozenUntil
        switch mode {
        case .touchpad:
            return .zero
        case .air:
            guard !frozen else {
                air.reset()
                return .zero
            }
            let step = air.movement(
                rotation: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
                gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
                dt: dt
            )
            return CGPoint(x: step.x, y: step.y)
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
}
