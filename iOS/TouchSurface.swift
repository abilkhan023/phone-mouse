import SwiftUI
import UIKit

struct TouchSurface: UIViewRepresentable {
    let onMove: (CGSize) -> Void
    let onScroll: (CGSize) -> Void
    let onTap: (Int) -> Void
    let onGesture: (GestureEvent.Kind) -> Void
    let onScrollState: (Bool) -> Void
    let onDrag: (Bool) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onMove = onMove
        view.onScroll = onScroll
        view.onTap = onTap
        view.onGesture = onGesture
        view.onScrollState = onScrollState
        view.onDrag = onDrag
    }
}

final class TouchSurfaceView: UIView {
    var onMove: ((CGSize) -> Void)?
    var onScroll: ((CGSize) -> Void)?
    var onTap: ((Int) -> Void)?
    var onGesture: ((GestureEvent.Kind) -> Void)?
    var onScrollState: ((Bool) -> Void)?
    var onDrag: ((Bool) -> Void)?

    private let tapDuration = 0.25
    private let tapTravel: CGFloat = 10
    private let swipeDistance: CGFloat = 60
    private let pinchRatio: CGFloat = 0.3
    private let zoomStep: CGFloat = 40

    private var active: Set<UITouch> = []
    private var startedAt: TimeInterval = 0
    private var travel: CGFloat = 0
    private var fingers = 0
    private var startCenter = CGPoint.zero
    private var startSpread: CGFloat = 0
    private var fired = false
    private var zooming = false
    private let dragWindow = 0.3
    private var lastTapAt: TimeInterval = 0
    // A touch that lands right after a tap may turn into a drag once it moves.
    private var mayDrag = false
    private var dragging = false {
        didSet {
            if dragging != oldValue {
                onDrag?(dragging)
            }
        }
    }
    // Two fingers resting in a scroll; the Mac glides on when this ends.
    private var scrolling = false {
        didSet {
            if scrolling != oldValue {
                onScrollState?(scrolling)
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if active.isEmpty {
            startedAt = event?.timestamp ?? 0
            travel = 0
            fingers = 0
            mayDrag = startedAt - lastTapAt < dragWindow
        }
        active.formUnion(touches)
        fingers = max(fingers, active.count)
        resetBaseline()
    }

    // Three or more fingers make one gesture per touch, like on a Mac
    // trackpad: a swipe, or with four or five fingers a pinch or a spread.
    private func resetBaseline() {
        startCenter = touchCenter
        startSpread = spread
    }

    private var touchCenter: CGPoint {
        let points = active.map { $0.location(in: self) }
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private var spread: CGFloat {
        let middle = touchCenter
        let distances = active.map { hypot($0.location(in: self).x - middle.x, $0.location(in: self).y - middle.y) }
        return distances.isEmpty ? 0 : distances.reduce(0, +) / CGFloat(distances.count)
    }

    private func recognizeMultiFinger() {
        guard !fired else { return }
        let now = touchCenter
        let shift = CGPoint(x: now.x - startCenter.x, y: now.y - startCenter.y)
        if active.count >= 4, startSpread > 0 {
            let ratio = spread / startSpread
            if ratio < 1 - pinchRatio { return fire(.pinchIn) }
            if ratio > 1 + pinchRatio { return fire(.spreadOut) }
        }
        guard hypot(shift.x, shift.y) > swipeDistance else { return }
        if abs(shift.x) > abs(shift.y) {
            fire(shift.x < 0 ? .swipeLeft : .swipeRight)
        } else {
            fire(shift.y < 0 ? .swipeUp : .swipeDown)
        }
    }

    private func fire(_ kind: GestureEvent.Kind) {
        fired = true
        onGesture?(kind)
    }

    // Two fingers scroll, unless they move apart or together more than they
    // travel, which zooms in steps.
    private func recognizeZoom() -> Bool {
        let change = spread - startSpread
        let shift = hypot(touchCenter.x - startCenter.x, touchCenter.y - startCenter.y)
        if !zooming, abs(change) > zoomStep * 0.75, abs(change) > shift {
            zooming = true
        }
        guard zooming else { return false }
        if abs(change) > zoomStep {
            onGesture?(change > 0 ? .zoomIn : .zoomOut)
            startSpread = spread
        }
        return true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var delta = CGSize.zero
        for touch in touches {
            let now = touch.preciseLocation(in: self)
            let before = touch.precisePreviousLocation(in: self)
            delta.width += now.x - before.x
            delta.height += now.y - before.y
        }
        let count = CGFloat(max(active.count, 1))
        delta.width /= count
        delta.height /= count
        travel += hypot(delta.width, delta.height)
        if fingers >= 3 {
            scrolling = false
            recognizeMultiFinger()
        } else if active.count == 2 {
            if recognizeZoom() {
                scrolling = false
            } else {
                scrolling = true
                onScroll?(delta)
            }
        } else if active.count == 1, fingers == 1 {
            if mayDrag, !dragging, travel > tapTravel / 2 {
                dragging = true
            }
            onMove?(delta)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        resetBaseline()
        if active.count < 2 {
            scrolling = false
        }
        guard active.isEmpty, let time = event?.timestamp else { return }
        defer {
            fired = false
            zooming = false
            mayDrag = false
        }
        if dragging {
            dragging = false
            return
        }
        guard !fired, !zooming, time - startedAt < tapDuration, travel < tapTravel else { return }
        if fingers >= 3 {
            onGesture?(.lookUp)
        } else {
            onTap?(fingers)
            lastTapAt = fingers == 1 ? time : 0
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        resetBaseline()
        if active.count < 2 {
            scrolling = false
        }
        if active.isEmpty {
            fired = false
            zooming = false
            mayDrag = false
            dragging = false
        }
    }
}
