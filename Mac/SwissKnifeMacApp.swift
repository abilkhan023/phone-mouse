import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct SwissKnifeMacApp: App {
    @State private var host = HostController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(host: host)
        } label: {
            MenuLabel(host: host)
        }
        Window("Pair iPhone", id: PairingView.windowID) {
            PairingView(host: host)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuLabel: View {
    let host: HostController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The app icon's cross with a pointer: outlined while waiting, filled once
        // the phone is connected.
        Image(host.isClientActive ? "MenuIconConnected" : "MenuIcon")
            .task {
                guard host.needsPairing else { return }
                NSApp.activate()
                openWindow(id: PairingView.windowID)
            }
    }
}

struct MenuContent: View {
    let host: HostController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(host.isClientActive ? String(localized: "Phone connected") : String(localized: "Waiting for phone…"))
        if !host.isTrusted {
            Button("Allow cursor control…") { host.requestAccess() }
        }
        Toggle("Share Clipboard", isOn: Binding(get: { host.syncsClipboard }, set: { host.syncsClipboard = $0 }))
        Toggle("Open at Login", isOn: Binding(get: { host.opensAtLogin }, set: { host.setOpensAtLogin($0) }))
        Button("Pair iPhone…") {
            NSApp.activate()
            openWindow(id: PairingView.windowID)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

struct PairingView: View {
    static let windowID = "pair"

    let host: HostController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan with Swiss Knife on your iPhone")
                .font(.headline)
            if let image = qrImage(host.pairing.code) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            }
            if let code = host.pairingCode {
                VStack(spacing: 4) {
                    Text("No camera handy? Choose Pair by code on the phone and type")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 280)
                    Text(code.prefix(3) + " " + code.suffix(3))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                }
            } else {
                Text("Too many wrong codes. Close this window and open it again for a new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 280)
            }
            Text("Only a phone paired with this Mac can control it. Traffic between them is encrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 280)
            Button("New code") { host.resetPairing() }
                .help("Unpairs the current phone")
        }
        .padding(24)
        .onAppear { host.beginCodePairing() }
        .onDisappear { host.endCodePairing() }
        .onChange(of: host.connections) {
            dismissWindow(id: Self.windowID)
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
