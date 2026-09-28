import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct PhoneMouseHostApp: App {
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
        Image(systemName: host.isClientActive ? "computermouse.fill" : "computermouse")
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
        Text(host.isClientActive ? "Phone connected" : "Waiting for phone…")
        if !host.isTrusted {
            Button("Allow cursor control…") { host.requestAccess() }
        }
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

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan with Phone Mouse on your iPhone")
                .font(.headline)
            if let image = qrImage(host.pairing.code) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            }
            Text("Only a phone that scanned this code can control this Mac. Traffic between them is encrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 280)
            Button("New code") { host.resetPairing() }
                .help("Unpairs the current phone")
        }
        .padding(24)
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
