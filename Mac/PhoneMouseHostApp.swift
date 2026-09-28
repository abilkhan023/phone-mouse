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
    }
}

struct MenuLabel: View {
    let host: HostController

    var body: some View {
        Image(systemName: host.isClientActive ? "computermouse.fill" : "computermouse")
    }
}

struct MenuContent: View {
    let host: HostController

    var body: some View {
        Text(host.isClientActive ? "Phone connected" : "Waiting for phone…")
        if !host.isTrusted {
            Button("Allow cursor control…") { host.requestAccess() }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
