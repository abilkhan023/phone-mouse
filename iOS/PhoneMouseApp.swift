import SwiftUI

@main
struct PhoneMouseApp: App {
    @State private var controller = MouseController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
