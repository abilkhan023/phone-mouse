import SwiftUI

// Today and all time, read again every second while the page is open.
struct StatsView: View {
    let stats: Stats
    let scheme: ColorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsReset = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Form {
                    section("Today", stats.today)
                    section("All time", stats.total)
                    Section {
                        Button("Reset statistics", role: .destructive) { confirmsReset = true }
                    } footer: {
                        Text("Counted on this iPhone only. Distances are on the Mac's screen.")
                    }
                }
            }
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset statistics?", isPresented: $confirmsReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { stats.reset() }
            } message: {
                Text("Today and all time start again from zero.")
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(scheme)
    }

    private func section(_ title: LocalizedStringKey, _ counts: Stats.Counts) -> some View {
        Section(title) {
            row("cursorarrow.motionlines", "Pointer travelled", distance(counts.pointer))
            row("cursorarrow.click.2", "Clicks", counts.clicks.formatted())
            row("arrow.up.and.down", "Scrolled", distance(counts.scroll))
            row("keyboard", "Characters typed", counts.characters.formatted())
            row("character.book.closed", "Translations", counts.translations.formatted())
            row("lock.open", "Unlocks", counts.unlocks.formatted())
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func distance(_ points: Double) -> String {
        Measurement(value: points * Stats.metresPerPoint, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
