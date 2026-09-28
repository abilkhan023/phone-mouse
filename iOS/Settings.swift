import Foundation
import Observation

@Observable
final class Settings {
    var pointerSpeed: Double { didSet { save(pointerSpeed, Self.pointerKey) } }
    var scrollSpeed: Double { didSet { save(scrollSpeed, Self.scrollKey) } }
    // Content follows the fingers, as on a Mac with its default setting.
    var naturalScrolling: Bool { didSet { save(naturalScrolling, Self.naturalKey) } }
    var showsLatency: Bool { didSet { save(showsLatency, Self.latencyKey) } }

    static let speedRange = 0.4...2.5

    private static let pointerKey = "pointerSpeed"
    private static let scrollKey = "scrollSpeed"
    private static let naturalKey = "naturalScrolling"
    private static let latencyKey = "showsLatency"

    init() {
        let defaults = UserDefaults.standard
        pointerSpeed = defaults.object(forKey: Self.pointerKey) as? Double ?? 1
        scrollSpeed = defaults.object(forKey: Self.scrollKey) as? Double ?? 1
        naturalScrolling = defaults.object(forKey: Self.naturalKey) as? Bool ?? true
        showsLatency = defaults.object(forKey: Self.latencyKey) as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
