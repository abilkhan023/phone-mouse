import SwiftUI

extension Animation {
    // The curve iOS moves its keyboard with, so the layout travels with it.
    static let keyboard = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
}

struct ContentView: View {
    let controller: MouseController
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardTop = CGFloat.infinity

    var body: some View {
        GeometryReader { safeArea in
            let insets = safeArea.safeAreaInsets
            let screenHeight = safeArea.size.height + insets.top + insets.bottom
            let keyboardHeight = max(screenHeight - keyboardTop, insets.bottom)
            ZStack(alignment: .top) {
                VolumeKeysView(keys: controller.volumeKeys)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                Shell(lit: controller.hostName != nil)
                VStack(spacing: 0) {
                    Group {
                        switch controller.mode {
                        case .air, .desk: ButtonDeck(controller: controller)
                        case .touchpad: TouchpadDeck(controller: controller)
                        }
                    }
                    .padding(.top, insets.top + 60)
                    if controller.isTyping {
                        VStack(spacing: 8) {
                            MacKeyStrip(controller: controller)
                            TypedLine(text: controller.typed)
                                .padding(.horizontal, 14)
                        }
                        .padding(.vertical, 8)
                        .padding(.bottom, keyboardHeight)
                    } else {
                        Hint(mode: controller.mode)
                            .frame(height: 76)
                            .padding(.bottom, insets.bottom)
                    }
                }
                StatusBar(controller: controller)
                    .padding(.top, insets.top)
                if controller.isPairing {
                    PairingSheet(controller: controller)
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.keyboard) {
                keyboardTop = frame.minY
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .vertical)
        .statusBarHidden()
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                controller.start()
            } else {
                controller.stop()
            }
        }
    }
}

struct Shell: View {
    let lit: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Palette.shellTop, Palette.shellBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            EllipticalGradient(
                colors: [Palette.led.opacity(0.6), Palette.led.opacity(0)],
                center: .top,
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
            .frame(height: 300)
            .opacity(lit ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: lit)
        }
    }
}

struct StatusBar: View {
    let controller: MouseController

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.isPairing = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pair with a Mac")
            Text(controller.hostName ?? "Looking for your Mac…")
                .font(.marking(15))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .allowsHitTesting(false)
            Spacer()
            ModeSwitch(mode: controller.mode) { controller.select($0) }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

struct ModeSwitch: View {
    let mode: PointerMode
    let onSelect: (PointerMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PointerMode.allCases, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(option.title)
                        .font(.marking(14))
                        .foregroundStyle(option == mode ? Palette.shellBottom : Palette.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(option == mode ? Palette.ink : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.groove.opacity(0.5), in: Capsule())
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: mode)
    }
}

struct PairingSheet: View {
    let controller: MouseController

    var body: some View {
        ZStack(alignment: .top) {
            Palette.shellBottom
            VStack(spacing: 20) {
                PairingScanner { controller.pair(with: $0) }
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Palette.groove, lineWidth: 2))
                Text("Pair with your Mac")
                    .font(.marking(22))
                    .foregroundStyle(Palette.ink)
                Text("On the Mac, open the Phone Mouse menu, choose Pair iPhone and point the camera at the code.")
                    .font(.marking(15))
                    .foregroundStyle(Palette.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if controller.pairing != nil {
                    Button("Cancel") { controller.isPairing = false }
                        .font(.marking(17))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.top, 70)
        }
        .ignoresSafeArea()
    }
}

struct Hint: View {
    let mode: PointerMode

    var body: some View {
        Text(mode.hint)
            .font(.marking(15))
            .foregroundStyle(Palette.ink.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

struct MacKeyStrip: View {
    let controller: MouseController

    private let height: CGFloat = 38
    private let extras: [(label: String, code: UInt8, name: String)] = [
        ("esc", KeyMap.escape, "Escape"),
        ("⇥", KeyMap.tab, "Tab"),
        ("⌦", KeyMap.forwardDelete, "Forward delete"),
        ("home", KeyMap.home, "Home"),
        ("end", KeyMap.end, "End"),
        ("pg↑", KeyMap.pageUp, "Page up"),
        ("pg↓", KeyMap.pageDown, "Page down"),
    ] + KeyMap.function.enumerated().map { ("F\($0.offset + 1)", $0.element, "F\($0.offset + 1)") }
    private let modifierKeys: [(label: String, modifier: KeyModifiers, name: String)] = [
        ("⌃", .control, "Control"),
        ("⌥", .option, "Option"),
        ("⌘", .command, "Command"),
        ("⇧", .shift, "Shift"),
    ]
    private let arrows: [(label: String, code: UInt8, name: String)] = [
        ("←", KeyMap.left, "Left arrow"),
        ("↑", KeyMap.up, "Up arrow"),
        ("↓", KeyMap.down, "Down arrow"),
        ("→", KeyMap.right, "Right arrow"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(extras, id: \.code) { key in
                        cap(key.label, name: key.name) { controller.press(key.code) }
                    }
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: 6) {
                ForEach(modifierKeys, id: \.modifier.rawValue) { key in
                    cap(key.label, name: key.name, lit: controller.modifiers.contains(key.modifier)) {
                        controller.toggle(key.modifier)
                    }
                }
                Spacer(minLength: 6)
                ForEach(arrows, id: \.code) { key in
                    cap(key.label, name: key.name) { controller.press(key.code) }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func cap(_ label: String, name: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.marking(16))
                .foregroundStyle(lit ? Palette.shellBottom : Palette.ink)
                .padding(.horizontal, 10)
                .frame(minWidth: 40, minHeight: height)
                .background(lit ? Palette.ink : Palette.pressed, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.groove, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

struct TypedLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 2) {
            Text(text.isEmpty ? "Start typing" : text)
                .font(.marking(17))
                .foregroundStyle(Palette.ink.opacity(text.isEmpty ? 0.5 : 1))
                .lineLimit(1)
                .truncationMode(.head)
            Rectangle()
                .fill(Palette.led)
                .frame(width: 2, height: 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.groove, lineWidth: 2))
        .accessibilityLabel("Typed text")
        .accessibilityValue(text)
    }
}

struct ButtonDeck: View {
    let controller: MouseController
    @GestureState private var leftPressed = false
    @GestureState private var rightPressed = false

    var body: some View {
        ZStack(alignment: .top) {
            DeckHalf(side: .left)
                .fill(leftPressed ? Palette.pressed : .clear)
            DeckHalf(side: .right)
                .fill(rightPressed ? Palette.pressed : .clear)
            DeckSeams()
                .stroke(Palette.groove, lineWidth: 2)
            pad(.left, pressed: $leftPressed, label: "Left button")
            pad(.right, pressed: $rightPressed, label: "Right button")
            Wheel { controller.scroll(by: CGSize(width: 0, height: $0)) }
                .frame(width: 60, height: 210)
                .padding(.top, 84)
        }
        .onChange(of: leftPressed) { _, value in controller.setButton(.left, pressed: value) }
        .onChange(of: rightPressed) { _, value in controller.setButton(.right, pressed: value) }
    }

    private func pad(_ side: DeckHalf.Side, pressed: GestureState<Bool>, label: String) -> some View {
        Color.clear
            .contentShape(DeckHalf(side: side))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(pressed) { _, state, _ in state = true }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

struct TouchpadDeck: View {
    let controller: MouseController
    @GestureState private var leftPressed = false
    @GestureState private var rightPressed = false

    private let corner: CGFloat = 28

    var body: some View {
        let isTyping = controller.isTyping
        VStack(spacing: 10) {
            TouchSurface(
                onMove: { controller.movePointer(by: $0) },
                onScroll: { controller.scroll(by: $0) },
                onTap: { controller.click($0 >= 2 ? .right : .left) },
                onGesture: { controller.gesture($0) }
            )
            .background(Palette.pressed, in: RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(Palette.groove, lineWidth: 2))
            .accessibilityLabel("Touchpad")
            HStack(spacing: 10) {
                key(isPressed: leftPressed, pressed: $leftPressed, label: "Left button")
                Button {
                    withAnimation(.keyboard) {
                        controller.isTyping.toggle()
                    }
                } label: {
                    Image(systemName: isTyping ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isTyping ? Palette.shellBottom : Palette.ink)
                        .frame(width: 76)
                        .frame(maxHeight: .infinity)
                        .background(isTyping ? Palette.ink : Palette.pressed, in: RoundedRectangle(cornerRadius: corner))
                        .overlay(RoundedRectangle(cornerRadius: corner).stroke(Palette.groove, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTyping ? "Hide keyboard" : "Show keyboard")
                key(isPressed: rightPressed, pressed: $rightPressed, label: "Right button")
            }
            .frame(height: isTyping ? 56 : 88)
        }
        .padding(.horizontal, 14)
        .background(
            KeyCapture(isActive: isTyping) { controller.type($0, text: $1) }
                .frame(width: 1, height: 1)
                .opacity(0)
        )
        .onChange(of: leftPressed) { _, value in controller.setButton(.left, pressed: value) }
        .onChange(of: rightPressed) { _, value in controller.setButton(.right, pressed: value) }
    }

    private func key(isPressed: Bool, pressed: GestureState<Bool>, label: String) -> some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(isPressed ? Palette.groove : Palette.pressed)
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(Palette.groove, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: corner))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(pressed) { _, state, _ in state = true }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

struct DeckHalf: Shape {
    enum Side {
        case left
        case right
    }

    let side: Side

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - DeckSeams.front))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX + rect.width / 4, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + DeckSeams.rise),
            control: CGPoint(x: rect.minX + rect.width / 4, y: rect.minY)
        )
        path.closeSubpath()
        guard side == .right else { return path }
        return path.applying(
            CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
        )
    }
}

struct DeckSeams: Shape {
    static let rise: CGFloat = 56
    static let front: CGFloat = 28

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + Self.rise))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + Self.rise),
            control: CGPoint(x: rect.midX, y: rect.minY - Self.rise)
        )
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - Self.front))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - Self.front),
            control: CGPoint(x: rect.midX, y: rect.maxY + Self.front)
        )
        return path
    }
}

struct Wheel: View {
    let onScroll: (CGFloat) -> Void
    @GestureState private var drag: CGFloat = 0
    @State private var settled: CGFloat = 0

    private let pitch: CGFloat = 14

    var body: some View {
        let travel = settled + drag
        Capsule()
            .fill(Palette.groove)
            .overlay {
                Canvas { context, size in
                    var y = travel.truncatingRemainder(dividingBy: pitch) - pitch
                    while y < size.height + pitch {
                        let ridge = CGRect(x: 0, y: y, width: size.width, height: 3)
                        context.fill(Path(ridge), with: .color(Palette.ridge))
                        y += pitch
                    }
                }
                .background(Palette.wheel)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.45), .clear, .black.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Capsule())
                .padding(6)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($drag) { value, state, _ in
                        onScroll(value.translation.height - state)
                        state = value.translation.height
                    }
                    .onEnded { settled += $0.translation.height }
            )
            .sensoryFeedback(.selection, trigger: Int((travel / pitch).rounded(.down)))
            .accessibilityLabel("Scroll wheel")
    }
}
