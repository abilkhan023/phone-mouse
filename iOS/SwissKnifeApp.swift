import SwiftUI

@main
struct SwissKnifeApp: App {
    @State private var controller = MouseController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
