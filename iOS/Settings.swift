import Foundation
import Observation

@Observable
final class Settings {
    var pointerSpeed: Double { didSet { save(pointerSpeed, Self.pointerKey) } }
    var scrollSpeed: Double { didSet { save(scrollSpeed, Self.scrollKey) } }
    // Content follows the fingers, as on a Mac with its default setting.
    var naturalScrolling: Bool { didSet { save(naturalScrolling, Self.naturalKey) } }
    var showsLatency: Bool { didSet { save(showsLatency, Self.latencyKey) } }
    // Swaps the two mouse buttons on screen, like the Mac's setting for
    // left-handed use.
    var leftHanded: Bool { didSet { save(leftHanded, Self.leftHandedKey) } }
    var connection: HostLink.Preference {
        didSet {
            save(connection.rawValue, Self.connectionKey)
            onConnectionChange?(connection)
        }
    }
    @ObservationIgnored var onConnectionChange: ((HostLink.Preference) -> Void)?
    // Empty means the phone's language.
    var dictationLanguage: String { didSet { save(dictationLanguage, Self.dictationKey) } }
    // What the Translate page translates into; empty means the phone's language.
    var translationLanguage: String { didSet { save(translationLanguage, Self.translationKey) } }
    // What it translates from; empty means told from the text.
    var translationSource: String { didSet { save(translationSource, Self.translationSourceKey) } }

    static let speedRange = 0.4...2.5

    private static let pointerKey = "pointerSpeed"
    private static let scrollKey = "scrollSpeed"
    private static let naturalKey = "naturalScrolling"
    private static let latencyKey = "showsLatency"
    private static let leftHandedKey = "leftHanded"
    private static let dictationKey = "dictationLanguage"
    private static let translationKey = "translationLanguage"
    private static let translationSourceKey = "translationSource"
    private static let connectionKey = "connection"

    init() {
        let defaults = UserDefaults.standard
        pointerSpeed = defaults.object(forKey: Self.pointerKey) as? Double ?? 1
        scrollSpeed = defaults.object(forKey: Self.scrollKey) as? Double ?? 1
        naturalScrolling = defaults.object(forKey: Self.naturalKey) as? Bool ?? true
        showsLatency = defaults.object(forKey: Self.latencyKey) as? Bool ?? true
        leftHanded = defaults.bool(forKey: Self.leftHandedKey)
        dictationLanguage = defaults.string(forKey: Self.dictationKey) ?? ""
        translationLanguage = defaults.string(forKey: Self.translationKey) ?? ""
        translationSource = defaults.string(forKey: Self.translationSourceKey) ?? ""
        connection = HostLink.Preference(rawValue: defaults.string(forKey: Self.connectionKey) ?? "") ?? .automatic
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
