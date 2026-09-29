import SwiftUI
import UniformTypeIdentifiers

struct RemoteDeck: View {
    let controller: MouseController
    @State private var macPassword = ""

    // Six pages fit in one row when short names take less room than long ones.
    init(controller: MouseController) {
        self.controller = controller
        UISegmentedControl.appearance().apportionsSegmentWidthsByContent = true
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Remote", selection: Binding(get: { controller.remoteTab }, set: { controller.remoteTab = $0 })) {
                ForEach(RemoteTab.shown, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch controller.remoteTab {
            case .media: MediaPad(controller: controller)
            case .slides: SlidesPad(controller: controller)
            case .apps: AppsPad(controller: controller)
            case .screen: ScreenPad(controller: controller)
            case .actions: ActionsPad(controller: controller)
            case .translate:
                if #available(iOS 18.0, *) {
                    TranslatePad(controller: controller)
                }
            }
        }
        .padding(.horizontal, 14)
        .alert("Mac password", isPresented: Binding(
            get: { controller.asksMacPassword },
            set: { if !$0 { controller.cancelMacPassword() } }
        )) {
            SecureField("Password", text: $macPassword)
            Button("Save and unlock") {
                controller.saveMacPassword(macPassword)
                macPassword = ""
            }
            Button("Cancel", role: .cancel) { macPassword = "" }
        } message: {
            Text("Kept on this iPhone and opened with Face ID. Sent to \(controller.hostName ?? "the Mac") only to unlock it.")
        }
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

// Apps open on the Mac with their windows, and browsers with their tabs. A tap
// on an app brings it forward, a tap on a window raises that window, a tap on
// a tab shows it, a swipe quits the app.
private struct AppsPad: View {
    let controller: MouseController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                RemoteButton(symbol: "macwindow.on.rectangle", name: "Next window ⌘`", height: 64, caption: true) {
                    controller.gesture(.nextWindow)
                }
                RemoteButton(symbol: "scope", name: "Find pointer", height: 64, caption: true) {
                    controller.gesture(.findPointer)
                }
            }
            HStack(spacing: 10) {
                RemoteButton(symbol: "chevron.backward", name: "Previous tab ⌃⇧⇥", height: 64, caption: true) {
                    controller.switchTab(forward: false)
                }
                RemoteButton(symbol: "chevron.forward", name: "Next tab ⌃⇥", height: 64, caption: true) {
                    controller.switchTab(forward: true)
                }
            }
            List {
                ForEach(controller.apps) { app in
                    Button { controller.perform(AppCommand(kind: .activate, pid: app.pid)) } label: {
                        HStack(spacing: 12) {
                            icon(app)
                            Text(app.name)
                                .font(.marking(16))
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            if app.active {
                                Circle().fill(Palette.led).frame(width: 8, height: 8)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Quit", role: .destructive) { controller.perform(AppCommand(kind: .quit, pid: app.pid)) }
                    }
                    .listRowBackground(Palette.pressed)
                    ForEach(app.windows, id: \.index) { window in
                        Button {
                            controller.perform(AppCommand(kind: .raiseWindow, pid: app.pid, window: window))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: window.minimized ? "minus.rectangle" : "macwindow")
                                    .font(.system(size: 13))
                                Text(window.title)
                                    .font(.marking(14))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Palette.ink.opacity(0.7))
                            .padding(.leading, 44)
                        }
                        .listRowBackground(Palette.pressed.opacity(0.6))
                        ForEach(window.tabs ?? [], id: \.index) { tab in
                            Button {
                                controller.perform(AppCommand(kind: .selectTab, pid: app.pid, window: window, tab: tab.index))
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(tab.active ? Palette.led : Palette.ink.opacity(0.25))
                                        .frame(width: 6, height: 6)
                                    Text(tab.title)
                                        .font(.marking(13))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(Palette.ink.opacity(tab.active ? 0.9 : 0.55))
                                .padding(.leading, 66)
                            }
                            .listRowBackground(Palette.pressed.opacity(0.4))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                if controller.apps.isEmpty {
                    Text("Loading the Mac's apps…")
                        .font(.marking(15))
                        .foregroundStyle(Palette.ink.opacity(0.6))
                }
            }
            .refreshable { controller.requestApps() }
        }
        .onAppear { controller.requestApps() }
    }

    @ViewBuilder
    private func icon(_ app: RunningApp) -> some View {
        if let data = app.icon, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().frame(width: 32, height: 32)
        } else {
            Image(systemName: "app").font(.system(size: 26)).frame(width: 32, height: 32)
        }
    }
}

// A live picture of the Mac's main display. A tap clicks at that spot, two
// taps double-click, and a finger sliding over it leads the cursor without
// clicking. Two fingers pinch to zoom in and move the picture around. The
// picture lies turned a quarter clockwise, so with the phone held sideways the
// Mac's wide screen fills the tall page.
private struct ScreenPad: View {
    let controller: MouseController
    @Environment(\.displayScale) private var displayScale

    private let hintHeight: CGFloat = 30

    var body: some View {
        GeometryReader { box in
            content
                .onAppear { request(for: box.size) }
                .onChange(of: box.size) { _, size in request(for: size) }
        }
        .onDisappear { controller.watchScreen(width: 0) }
    }

    // The Mac's width lies along the page's height, so frames are asked for
    // that many pixels wide.
    private func request(for size: CGSize) {
        controller.watchScreen(width: Int((size.height - hintHeight - 12) * displayScale))
    }

    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Palette.groove)
            if let image = controller.screenImage {
                VStack(spacing: 8) {
                    ZoomableScreen(image: shown(image)) { spot, click in
                        point(spot, click: click)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Tap to click · slide to move · pinch to zoom")
                        .font(.marking(12))
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .frame(height: hintHeight - 8)
                }
                .padding(6)
            } else {
                Text("Waiting for the Mac screen…\nIf it does not come, allow Screen Recording for PhoneMouseHost on the Mac, in System Settings, Privacy & Security.")
                    .font(.marking(14))
                    .foregroundStyle(Palette.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func shown(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .right)
    }

    // The spot is in the picture as shown, from 0 to 1 each way. Turned a
    // quarter clockwise, the Mac's left edge is at the top of the picture
    // and its top edge on the right.
    private func point(_ spot: CGPoint, click: Bool) {
        let u = min(max(spot.x, 0), 1)
        let v = min(max(spot.y, 0), 1)
        controller.point(atX: v, y: 1 - u, click: click)
    }
}

// The picture in a scroll view, which zooms with a pinch around the fingers
// and moves with two fingers. One finger still points: a tap clicks, a slide
// leads the cursor, at the spot under the finger whatever the zoom. Two taps
// with two fingers show the whole screen again.
private struct ZoomableScreen: UIViewRepresentable {
    let image: UIImage
    let onPoint: (CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> ScreenScrollView {
        ScreenScrollView()
    }

    func updateUIView(_ view: ScreenScrollView, context: Context) {
        view.onPoint = onPoint
        view.show(image)
    }
}

private final class ScreenScrollView: UIScrollView, UIScrollViewDelegate {
    var onPoint: ((CGPoint, Bool) -> Void)?
    private let imageView = UIImageView()
    private var fittedFor = CGSize.zero
    private var lastPointAt: TimeInterval = 0
    private let pointInterval = 1.0 / 30
    private let maxZoom: CGFloat = 4

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = maxZoom
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        panGestureRecognizer.minimumNumberOfTouches = 2
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let slide = UIPanGestureRecognizer(target: self, action: #selector(slid))
        slide.maximumNumberOfTouches = 1
        imageView.addGestureRecognizer(tap)
        imageView.addGestureRecognizer(slide)
        let whole = UITapGestureRecognizer(target: self, action: #selector(showWhole))
        whole.numberOfTouchesRequired = 2
        whole.numberOfTapsRequired = 2
        addGestureRecognizer(whole)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // Frames of the same size keep the zoom; a new size, as when the Mac
    // changes resolution, starts over from the whole screen.
    func show(_ image: UIImage) {
        let resized = imageView.image?.size != image.size
        imageView.image = image
        if resized {
            fittedFor = .zero
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0, bounds.size != fittedFor else { return }
        fittedFor = bounds.size
        zoomScale = 1
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        contentSize = imageView.frame.size
        centre()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
    }

    // Keeps the picture in the middle while it is smaller than the view.
    private func centre() {
        let size = imageView.frame.size
        contentInset = UIEdgeInsets(
            top: max((bounds.height - size.height) / 2, 0),
            left: max((bounds.width - size.width) / 2, 0),
            bottom: 0,
            right: 0
        )
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        report(tap.location(in: imageView), click: true)
    }

    @objc private func slid(_ slide: UIPanGestureRecognizer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard slide.state == .ended || now - lastPointAt > pointInterval else { return }
        lastPointAt = now
        report(slide.location(in: imageView), click: false)
    }

    @objc private func showWhole() {
        setZoomScale(1, animated: true)
    }

    // The image view's own bounds do not grow with the zoom, so the spot
    // comes out the same at any zoom.
    private func report(_ location: CGPoint, click: Bool) {
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        onPoint?(CGPoint(x: location.x / size.width, y: location.y / size.height), click)
    }
}

private struct ActionsPad: View {
    let controller: MouseController

    private let actions: [(symbol: String, name: String, detail: String, kind: GestureEvent.Kind)] = [
        ("scope", "Find the pointer", "Rings the cursor on the Mac. Shaking the phone does it too.", .findPointer),
        ("macwindow.on.rectangle", "Next window", "Brings the front app's next window forward, like ⌘`.", .nextWindow),
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
                    if action.kind == .lockScreen {
                        unlockRow
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

    // Touched like the rows around it; the menu on the right changes or
    // forgets the saved password.
    private var unlockRow: some View {
        HStack(spacing: 8) {
            RepeatKey(repeats: false, action: { controller.unlockMac() }) { pressed in
                row(symbol: "lock.open.fill", name: "Unlock Mac", detail: "Types the Mac's password on its lock screen, after Face ID.", pressed: pressed)
            }
            Menu {
                Button("Change password", systemImage: "key.fill") { controller.changeMacPassword() }
                Button("Forget password", systemImage: "trash", role: .destructive) { controller.forgetMacPassword() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 60)
                    .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.groove, lineWidth: 2))
            }
            .accessibilityLabel("Password options")
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
                    Toggle("Left-handed", isOn: $settings.leftHanded)
                } footer: {
                    Text("Swaps the left and right mouse buttons on the screen.")
                }
                Section {
                    Picker("Dictation language", selection: $settings.dictationLanguage) {
                        Text("Same as the phone").tag("")
                        ForEach(Dictation.languages, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    Picker("Connection", selection: $settings.connection) {
                        Text("Automatic").tag(HostLink.Preference.automatic)
                        Text("Cable only").tag(HostLink.Preference.cable)
                        Text("Wi-Fi only").tag(HostLink.Preference.wifi)
                    }
                    Toggle("Show connection and delay", isOn: $settings.showsLatency)
                } footer: {
                    Text("Automatic uses a cable when one is plugged in and the Mac answers over it, and Wi-Fi otherwise.")
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
