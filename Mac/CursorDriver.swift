import AppKit

final class CursorDriver {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let resyncInterval = 0.1
    private let multiClickDistance = 12.0

    private var position = CGPoint.zero
    private var lastPostAt: TimeInterval = 0
    private var buttons: MouseButtons = []
    private var scrollRemainder = CGSize.zero
    private var lastDown: (button: MouseButtons, time: TimeInterval, point: CGPoint, count: Int64)?

    func apply(_ report: MouseReport) {
        move(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        setButtons(report.buttons)
        scroll(dx: CGFloat(report.scrollX), dy: CGFloat(report.scrollY))
    }

    func releaseButtons() {
        setButtons([])
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
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)?
            .post(tap: .cghidEventTap)
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
        event.post(tap: .cghidEventTap)
    }
}
