import Foundation

// How much the phone has been used, for the Statistics page: today and all
// time, kept on the phone only. Counting happens a hundred times a second,
// so it is plain storage, saved now and then rather than on every change.
final class Stats {
    struct Counts: Codable, Equatable {
        // Pointer and scroll travel in the Mac's points.
        var pointer: Double = 0
        var scroll: Double = 0
        var clicks = 0
        var characters = 0
        var translations = 0
        var unlocks = 0

        mutating func add(_ other: Counts) {
            pointer += other.pointer
            scroll += other.scroll
            clicks += other.clicks
            characters += other.characters
            translations += other.translations
            unlocks += other.unlocks
        }
    }

    // A Mac shows about a hundred points to the inch, a quarter of a
    // millimetre each.
    static let metresPerPoint = 0.000254

    private(set) var today = Counts()
    private(set) var total = Counts()
    private var day: String
    private var dirty = false

    private static let key = "stats"

    private struct Stored: Codable {
        var day: String
        var today: Counts
        var total: Counts
    }

    init() {
        day = Self.dayKey()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            total = stored.total
            if stored.day == day {
                today = stored.today
            }
        }
    }

    func record(_ change: (inout Counts) -> Void) {
        rollOver()
        var delta = Counts()
        change(&delta)
        today.add(delta)
        total.add(delta)
        dirty = true
    }

    func save() {
        guard dirty else { return }
        dirty = false
        let stored = Stored(day: day, today: today, total: total)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func reset() {
        today = Counts()
        total = Counts()
        dirty = true
        save()
    }

    // Today starts over at midnight.
    private func rollOver() {
        let now = Self.dayKey()
        guard now != day else { return }
        day = now
        today = Counts()
    }

    private static func dayKey() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
