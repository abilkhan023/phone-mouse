import SwiftUI
import UIKit

// Touch handling for the Mac key row. A plain UIView, not a control, so a
// scroll view that starts scrolling cancels the touch instead of pressing the
// key.
struct KeyTouch: UIViewRepresentable {
    let onDown: () -> Void
    let onUp: (_ completed: Bool) -> Void

    func makeUIView(context: Context) -> KeyTouchView {
        KeyTouchView()
    }

    func updateUIView(_ view: KeyTouchView, context: Context) {
        view.onDown = onDown
        view.onUp = onUp
    }
}

final class KeyTouchView: UIView {
    var onDown: (() -> Void)?
    var onUp: ((Bool) -> Void)?

    private var isDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isDown else { return }
        isDown = true
        onDown?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(completed: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(completed: false)
    }

    override func removeFromSuperview() {
        finish(completed: false)
        super.removeFromSuperview()
    }

    private func finish(completed: Bool) {
        guard isDown else { return }
        isDown = false
        onUp?(completed)
    }
}

// A key that types once on a tap and repeats while held, like a Mac key.
struct RepeatKey<Label: View>: View {
    var repeats = true
    let action: () -> Void
    @ViewBuilder let label: (_ pressed: Bool) -> Label

    @State private var pressed = false
    @State private var timer: Timer?
    @State private var repeated = false

    private let delay = 0.4
    private let interval = 0.06

    var body: some View {
        label(pressed)
            .overlay(KeyTouch(onDown: down, onUp: up))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func down() {
        pressed = true
        repeated = false
        guard repeats else { return }
        let action = action
        let interval = interval
        let start = Timer(timeInterval: delay, repeats: false) { _ in
            repeated = true
            action()
            let repeating = Timer(timeInterval: interval, repeats: true) { _ in action() }
            RunLoop.main.add(repeating, forMode: .common)
            timer = repeating
        }
        RunLoop.main.add(start, forMode: .common)
        timer = start
    }

    private func up(_ completed: Bool) {
        pressed = false
        timer?.invalidate()
        timer = nil
        if completed, !repeated {
            action()
        }
    }
}

// A modifier key: down on the Mac while the finger is on it.
struct HoldKey<Label: View>: View {
    let onDown: () -> Void
    let onUp: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .overlay(KeyTouch(onDown: onDown, onUp: { _ in onUp() }))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onDown()
                onUp()
            }
    }
}
