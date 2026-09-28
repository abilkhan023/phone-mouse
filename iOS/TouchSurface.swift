import SwiftUI
import UIKit

struct TouchSurface: UIViewRepresentable {
    let onMove: (CGSize) -> Void
    let onScroll: (CGSize) -> Void
    let onTap: (Int) -> Void

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
    }
}

final class TouchSurfaceView: UIView {
    var onMove: ((CGSize) -> Void)?
    var onScroll: ((CGSize) -> Void)?
    var onTap: ((Int) -> Void)?

    private let tapDuration = 0.25
    private let tapTravel: CGFloat = 10

    private var active: Set<UITouch> = []
    private var startedAt: TimeInterval = 0
    private var travel: CGFloat = 0
    private var fingers = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if active.isEmpty {
            startedAt = event?.timestamp ?? 0
            travel = 0
            fingers = 0
        }
        active.formUnion(touches)
        fingers = max(fingers, active.count)
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
        if active.count >= 2 {
            onScroll?(delta)
        } else {
            onMove?(delta)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty, let time = event?.timestamp else { return }
        if time - startedAt < tapDuration, travel < tapTravel {
            onTap?(fingers)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
    }
}
