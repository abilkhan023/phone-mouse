import SwiftUI
import UniformTypeIdentifiers

struct RemoteDeck: View {
    let controller: MouseController

    var body: some View {
        VStack(spacing: 14) {
            Picker("Remote", selection: Binding(get: { controller.remoteTab }, set: { controller.remoteTab = $0 })) {
                ForEach(RemoteTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch controller.remoteTab {
            case .media: MediaPad(controller: controller)
            case .slides: SlidesPad(controller: controller)
            case .actions: ActionsPad(controller: controller)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct MediaPad: View {
    let controller: MouseController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                pad("backward.fill", "Previous track") { controller.media(6) }
                pad("playpause.fill", "Play or pause", tall: true) { controller.media(7) }
                pad("forward.fill", "Next track") { controller.media(8) }
            }
            HStack(spacing: 12) {
                pad("speaker.wave.1.fill", "Volume down", repeats: true) { controller.media(10) }
                pad("speaker.slash.fill", "Mute") { controller.media(9) }
                pad("speaker.wave.3.fill", "Volume up", repeats: true) { controller.media(11) }
            }
            HStack(spacing: 12) {
                pad("sun.min.fill", "Brightness down", repeats: true) { controller.media(0) }
                pad("sun.max.fill", "Brightness up", repeats: true) { controller.media(1) }
            }
            Text("The volume buttons set the Mac's volume.")
                .font(.marking(14))
                .foregroundStyle(Palette.ink.opacity(0.6))
            Spacer(minLength: 0)
        }
    }

    private func pad(_ symbol: String, _ name: String, tall: Bool = false, repeats: Bool = false, action: @escaping () -> Void) -> some View {
        RemoteButton(symbol: symbol, name: name, height: tall ? 120 : 96, repeats: repeats, caption: true, action: action)
    }
}

private struct SlidesPad: View {
    let controller: MouseController
    @State private var laser = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RemoteButton(symbol: "chevron.left", name: "Previous slide", height: 150, caption: true) { controller.slide(forward: false) }
                RemoteButton(symbol: "chevron.right", name: "Next slide", height: 150, caption: true) { controller.slide(forward: true) }
            }
            HoldKey(onDown: { set(true) }, onUp: { set(false) }) {
                VStack(spacing: 8) {
                    Image(systemName: "light.max")
                        .font(.system(size: 34, weight: .medium))
                    Text(laser ? "Point at the screen" : "Hold to point")
                        .font(.marking(17))
                }
                .foregroundStyle(laser ? Palette.shellBottom : Palette.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(laser ? Palette.led : Palette.pressed, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Palette.groove, lineWidth: 2))
            }
            .accessibilityLabel("Laser pointer")
            Text("Volume buttons turn the slides too.")
                .font(.marking(14))
                .foregroundStyle(Palette.ink.opacity(0.6))
        }
    }

    private func set(_ held: Bool) {
        laser = held
        controller.setLaser(held)
    }
}

private struct ActionsPad: View {
    let controller: MouseController

    private let actions: [(symbol: String, name: String, detail: String, kind: GestureEvent.Kind)] = [
        ("lock.fill", "Lock screen", "Locks the Mac; unlock it with your password.", .lockScreen),
        ("moon.fill", "Display sleep", "Turns the screen off. Move the pointer to wake it.", .displaySleep),
        ("camera.viewfinder", "Screenshot", "Saves the whole screen as a picture on the Desktop.", .screenshot),
        ("crop", "Screenshot of an area", "Then drag on the Mac over the part to capture.", .screenshotArea),
        ("record.circle", "Screenshot tools", "Opens the panel for screen recording and options.", .screenshotTools),
        ("rectangle.3.group", "Mission Control", "Shows every open window and desktop at once.", .swipeUp),
        ("menubar.dock.rectangle", "Show desktop", "Moves the windows aside; again to bring them back.", .spreadOut),
        ("square.grid.3x3.fill", "Apps", "Opens the list of all installed apps.", .pinchIn),
        ("face.smiling", "Emoji", "Opens the emoji picker where the text cursor is.", .emoji),
        ("xmark.octagon.fill", "Force quit", "Opens the window for closing an app that hangs.", .forceQuit),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(actions, id: \.name) { action in
                    RepeatKey(repeats: false, action: { controller.gesture(action.kind) }) { pressed in
                        row(symbol: action.symbol, name: action.name, detail: action.detail, pressed: pressed)
                    }
                }
                HStack(spacing: 12) {
                    ClipboardButton(controller: controller)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send clipboard")
                            .font(.marking(16))
                        Text("Puts the text or image copied on the phone on the Mac.")
                            .font(.marking(12))
                            .opacity(0.6)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 60)
                .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.groove, lineWidth: 2))
            }
        }
    }

    private func row(symbol: String, name: String, detail: String, pressed: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.marking(16))
                Text(detail)
                    .font(.marking(12))
                    .opacity(0.6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(pressed ? Palette.shellBottom : Palette.ink)
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .background(pressed ? Palette.ink : Palette.pressed, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.groove, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

struct RemoteButton: View {
    let symbol: String
    let name: String
    var height: CGFloat = 96
    var repeats = false
    var caption = false
    let action: () -> Void

    var body: some View {
        RepeatKey(repeats: repeats, action: action) { pressed in
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: caption ? 24 : 30, weight: .medium))
                if caption {
                    Text(name)
                        .font(.marking(12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(pressed ? Palette.shellBottom : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(pressed ? Palette.ink : Palette.pressed, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.groove, lineWidth: 2))
            .accessibilityLabel(name)
        }
    }
}

// The system paste button reads the clipboard without iOS asking for
// permission each time, so phone-to-Mac goes through it.
struct ClipboardButton: View {
    let controller: MouseController
    var large = false

    var body: some View {
        PasteButton(supportedContentTypes: [.image, .plainText]) { providers in
            controller.sendClipboard(providers)
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.roundedRectangle(radius: large ? 24 : 10))
        .tint(Palette.pressed)
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: large ? .infinity : nil)
        .frame(height: large ? 92 : 38)
        .accessibilityLabel("Send clipboard to the Mac")
    }
}

struct SettingsView: View {
    @Bindable var settings: Settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Speed") {
                    slider("Pointer", value: $settings.pointerSpeed)
                    slider("Scrolling", value: $settings.scrollSpeed)
                }
                Section {
                    Toggle("Natural scrolling", isOn: $settings.naturalScrolling)
                } footer: {
                    Text("Content follows your fingers, as on a Mac trackpad.")
                }
                Section {
                    Toggle("Show connection and delay", isOn: $settings.showsLatency)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("×").foregroundStyle(.secondary)
            }
            Slider(value: value, in: Settings.speedRange, step: 0.1)
        }
    }
}
