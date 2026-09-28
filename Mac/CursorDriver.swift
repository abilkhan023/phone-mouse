import AppKit

final class CursorDriver {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let resyncInterval = 0.1
    private let multiClickDistance = 12.0
    private let smoothRate = 1.0 / 240
    private let reportInterval = 0.01
    private let minLag = 0.004
    private let maxLag = 0.025
    private let jitterWeight = 0.05

    private var position = CGPoint.zero
    private var lastPostAt: TimeInterval = 0
    private var buttons: MouseButtons = []
    private var scrollRemainder = CGSize.zero
    private var lastDown: (button: MouseButtons, time: TimeInterval, point: CGPoint, count: Int64)?
    private var pending = CGSize.zero
    private var jitter = 0.0
    private var lastArrival: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var timer: Timer?
    private var isScrolling = false
    private var scrollBegan = false
    private var recentScroll: [(time: TimeInterval, delta: CGSize)] = []
    private var velocity = CGSize.zero
    private var momentumTimer: Timer?
    private var momentumStarted = false
    private var lastMomentumTick: TimeInterval = 0
    private let velocityWindow = 0.1
    private let momentumDecay = 0.33
    private let momentumFloor = 15.0
    private let momentumStart = 60.0
    private let momentumRate = 1.0 / 120
    // Modifiers held on the phone, so ⌘-click and ⌥-drag work.
    var flags = CGEventFlags()

    func apply(_ report: MouseReport) {
        track(arrivalAt: ProcessInfo.processInfo.systemUptime)
        pending.width += CGFloat(report.dx)
        pending.height += CGFloat(report.dy)
        if report.buttons != buttons {
            flush()
        }
        setButtons(report.buttons)
        if report.isScrolling || isScrolling {
            touchScroll(dx: CGFloat(report.scrollX), dy: CGFloat(report.scrollY), active: report.isScrolling)
        } else {
            scroll(dx: CGFloat(report.scrollX), dy: CGFloat(report.scrollY))
        }
        startSmoothing()
    }

    func releaseButtons() {
        flush()
        setButtons([])
        if isScrolling {
            touchScroll(dx: 0, dy: 0, active: false)
        }
    }

    // Scrolling with fingers on the touchpad is posted with the phases of a
    // real trackpad, so apps show their rubber band and swipe back works, and
    // after the fingers lift the page glides on and slows down.
    private func touchScroll(dx: CGFloat, dy: CGFloat, active: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if active {
            if !isScrolling {
                stopMomentum()
                isScrolling = true
                scrollBegan = false
                recentScroll = []
                scrollRemainder = .zero
            }
            recentScroll.append((now, CGSize(width: dx, height: dy)))
            recentScroll.removeAll { now - $0.time > velocityWindow }
            guard dx != 0 || dy != 0 else { return }
            postScroll(dx: dx, dy: dy, phase: scrollBegan ? 2 : 1, momentum: 0)
            scrollBegan = true
            return
        }
        isScrolling = false
        guard scrollBegan else { return }
        postScroll(dx: 0, dy: 0, phase: 4, momentum: 0)
        recentScroll.removeAll { now - $0.time > velocityWindow }
        let total = recentScroll.reduce(CGSize.zero) { CGSize(width: $0.width + $1.delta.width, height: $0.height + $1.delta.height) }
        velocity = CGSize(width: total.width / velocityWindow, height: total.height / velocityWindow)
        if hypot(velocity.width, velocity.height) > momentumStart {
            startMomentum()
        }
    }

    private func startMomentum() {
        momentumStarted = false
        lastMomentumTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: momentumRate, repeats: true) { [weak self] _ in self?.glide() }
        RunLoop.main.add(timer, forMode: .common)
        momentumTimer = timer
    }

    private func glide() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastMomentumTick
        lastMomentumTick = now
        let fade = CGFloat(exp(-dt / momentumDecay))
        velocity = CGSize(width: velocity.width * fade, height: velocity.height * fade)
        guard hypot(velocity.width, velocity.height) > momentumFloor else {
            stopMomentum()
            return
        }
        postScroll(dx: velocity.width * dt, dy: velocity.height * dt, phase: 0, momentum: momentumStarted ? 2 : 1)
        momentumStarted = true
    }

    private func stopMomentum() {
        guard let momentumTimer else { return }
        momentumTimer.invalidate()
        self.momentumTimer = nil
        if momentumStarted {
            postScroll(dx: 0, dy: 0, phase: 0, momentum: 3)
        }
        momentumStarted = false
    }

    private func postScroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64) {
        scrollRemainder.width += dx
        scrollRemainder.height += dy
        let x = Int32(scrollRemainder.width.rounded(.towardZero))
        let y = Int32(scrollRemainder.height.rounded(.towardZero))
        let edge = phase == 1 || phase == 4 || momentum == 1 || momentum == 3
        guard x != 0 || y != 0 || edge else { return }
        scrollRemainder.width -= CGFloat(x)
        scrollRemainder.height -= CGFloat(y)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if !flags.isEmpty {
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
    }

    // Over Wi-Fi reports arrive in bursts. Movement is queued and let out at
    // display rate, trailing behind by about as much as the arrival times
    // wobble, so the cursor glides instead of jumping.
    private func track(arrivalAt now: TimeInterval) {
        defer { lastArrival = now }
        let gap = now - lastArrival
        guard gap < 0.2 else { return }
        jitter += (abs(gap - reportInterval) - jitter) * jitterWeight
    }

    private var lag: TimeInterval {
        min(max(jitter * 2, minLag), maxLag)
    }

    private func startSmoothing() {
        guard timer == nil, pending != .zero else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: smoothRate, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        let share = CGFloat(1 - exp(-dt / lag))
        var step = CGSize(width: pending.width * share, height: pending.height * share)
        if hypot(pending.width - step.width, pending.height - step.height) < 0.05 {
            step = pending
        }
        pending.width -= step.width
        pending.height -= step.height
        move(dx: step.width, dy: step.height)
        if pending == .zero {
            timer?.invalidate()
            timer = nil
        }
    }

    private func flush() {
        move(dx: pending.width, dy: pending.height)
        pending = .zero
    }

    private func move(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        sync()
        position = clamp(CGPoint(x: position.x + dx, y: position.y + dy))
        if buttons.contains(.left) {
            post(.leftMouseDragged, button: .left)
        } else if buttons.contains(.right) {
            post(.rightMouseDragged, button: .right)
        } else {
            post(.mouseMoved, button: .left)
        }
    }

    private func setButtons(_ new: MouseButtons) {
        guard new != buttons else { return }
        sync()
        update(.left, in: new, cgButton: .left, down: .leftMouseDown, up: .leftMouseUp)
        update(.right, in: new, cgButton: .right, down: .rightMouseDown, up: .rightMouseUp)
        buttons = new
    }

    private func update(_ button: MouseButtons, in new: MouseButtons, cgButton: CGMouseButton, down: CGEventType, up: CGEventType) {
        let pressed = new.contains(button)
        guard pressed != buttons.contains(button) else { return }
        if pressed {
            post(down, button: cgButton, clickState: nextClickCount(for: button))
        } else {
            post(up, button: cgButton, clickState: lastDown?.button == button ? lastDown?.count ?? 1 : 1)
        }
    }

    private func nextClickCount(for button: MouseButtons) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        var count: Int64 = 1
        if let last = lastDown,
           last.button == button,
           now - last.time < NSEvent.doubleClickInterval,
           hypot(position.x - last.point.x, position.y - last.point.y) < multiClickDistance {
            count = last.count + 1
        }
        lastDown = (button, now, position, count)
        return count
    }

    private func scroll(dx: CGFloat, dy: CGFloat) {
        scrollRemainder.width += dx
        scrollRemainder.height += dy
        let x = Int32(scrollRemainder.width.rounded(.towardZero))
        let y = Int32(scrollRemainder.height.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        scrollRemainder.width -= CGFloat(x)
        scrollRemainder.height -= CGFloat(y)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        if !flags.isEmpty {
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
    }

    private func sync() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastPostAt = now }
        guard now - lastPostAt > resyncInterval, let system = CGEvent(source: nil)?.location else { return }
        position = system
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let candidates = displays.prefix(Int(count)).map { display -> CGPoint in
            let bounds = CGDisplayBounds(display)
            return CGPoint(
                x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                y: min(max(point.y, bounds.minY), bounds.maxY - 1)
            )
        }
        return candidates.min {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        } ?? point
    }

    private func post(_ type: CGEventType, button: CGMouseButton, clickState: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if !flags.isEmpty {
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
    }
}
