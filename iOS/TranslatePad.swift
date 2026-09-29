import NaturalLanguage
import SwiftUI
import Translation

struct TranslatedText: Identifiable, Equatable {
    let id = UUID()
    var original: String
    var translation: String?
    // Language codes, such as "en"; the source is nil when it is unknown.
    var source: String?
    var target: String
    // Why there is no translation, or that none was needed.
    var note: String?
}

extension Settings {
    // The language set in settings, or else the phone's.
    var translationTarget: Locale.Language {
        Locale.Language(identifier: translationLanguage.isEmpty ? Locale.preferredLanguages.first ?? "en" : translationLanguage)
    }
}

// Text selected on the Mac, translated on the phone as soon as it comes. The
// Mac reads the selection only while this page is on view. Translation runs on
// the phone, with the languages iOS offers; the first use of a pair asks to
// download it.
@available(iOS 18.0, *)
struct TranslatePad: View {
    let controller: MouseController
    @State private var configuration: TranslationSession.Configuration?
    @State private var pending: String?
    // Which language the list on view picks.
    @State private var choosing: Side?
    @State private var languages: [(id: String, name: String)] = []

    private let sideShare = 0.36

    private enum Side {
        case source
        case target
    }

    // The page lies turned a quarter clockwise, like the mini screen, so with
    // the phone held sideways the translation gets the long side.
    var body: some View {
        GeometryReader { box in
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let choosing {
                        languageList(choosing)
                    } else if let current = controller.translations.first {
                        card(current)
                    } else {
                        empty
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    languageButtons
                    takeButton
                    history
                }
                .frame(width: box.size.height * sideShare)
            }
            .frame(width: box.size.height, height: box.size.width)
            .rotationEffect(.degrees(90))
            .frame(width: box.size.width, height: box.size.height)
        }
        .task { languages = await Self.targets() }
        .onAppear { controller.watchSelection(true) }
        .onDisappear { controller.watchSelection(false) }
        .onChange(of: controller.selectedText) { _, text in
            if let text { translate(text) }
        }
        .translationTask(configuration) { session in
            guard let text = pending else { return }
            pending = nil
            let target = configuration?.target?.minimalIdentifier ?? ""
            do {
                let response = try await session.translate(text)
                controller.remember(TranslatedText(
                    original: text,
                    translation: response.targetText,
                    source: response.sourceLanguage.languageCode?.identifier,
                    target: target
                ))
            } catch {
                controller.remember(TranslatedText(original: text, source: nil, target: target, note: "Could not translate. \(error.localizedDescription)"))
            }
        }
    }

    // Unless a source language is chosen, it is told apart on the phone first,
    // so text already in the target language is shown as it is and a
    // language iOS cannot translate gets a way out.
    private func translate(_ text: String) {
        let target = controller.settings.translationTarget
        let targetCode = target.languageCode?.identifier ?? ""
        let chosen = controller.settings.translationSource
        let detected = chosen.isEmpty
            ? NLLanguageRecognizer.dominantLanguage(for: text).map { Locale.Language(identifier: $0.rawValue) }
            : Locale.Language(identifier: chosen)
        let sourceCode = detected?.languageCode?.identifier
        if sourceCode == targetCode {
            controller.remember(TranslatedText(original: text, source: sourceCode, target: targetCode, note: "Already in \(name(of: targetCode))."))
            return
        }
        Task {
            if let detected, await LanguageAvailability().status(from: detected, to: target) == .unsupported {
                controller.remember(TranslatedText(original: text, source: sourceCode, target: targetCode, note: "iOS cannot translate \(name(of: sourceCode ?? "")) yet."))
                return
            }
            pending = text
            if configuration?.source == detected, configuration?.target == target {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: detected, target: target)
            }
        }
    }

    // From and to, one above the other, and a button that swaps them.
    private var languageButtons: some View {
        let settings = controller.settings
        let source = settings.translationSource
        return HStack(spacing: 6) {
            VStack(spacing: 6) {
                sideButton(.source, source.isEmpty ? "Auto" : name(of: source))
                sideButton(.target, "→ \(name(of: settings.translationTarget.languageCode?.identifier ?? ""))")
            }
            Button(action: swapLanguages) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: 86)
                    .background(Palette.shellTop, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.groove, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Swap languages")
        }
    }

    private func sideButton(_ side: Side, _ title: String) -> some View {
        Button { choosing = choosing == side ? nil : side } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: choosing == side ? "xmark" : "chevron.down")
            }
            .font(.marking(16))
            .foregroundStyle(choosing == side ? Palette.shellBottom : Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(choosing == side ? Palette.ink : Palette.shellTop, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.groove, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(side == .source ? "Language to translate from" : "Language to translate into")
    }

    // With the source told from the text, the language of the last
    // translation takes its place. The next selection is translated the
    // other way; the one on view stays as it is.
    private func swapLanguages() {
        let settings = controller.settings
        let source = settings.translationSource.isEmpty ? controller.translations.first?.source ?? "" : settings.translationSource
        guard !source.isEmpty else { return }
        settings.translationSource = settings.translationTarget.minimalIdentifier
        settings.translationLanguage = source
        choosing = nil
    }

    // In the page rather than a menu, so it lies sideways with the page.
    private func languageList(_ side: Side) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                languageCell(side, id: "", name: side == .source ? "Auto" : "Same as the phone")
                ForEach(languages, id: \.id) { languageCell(side, id: $0.id, name: $0.name) }
            }
            .padding(8)
        }
        .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.groove, lineWidth: 2))
    }

    private func languageCell(_ side: Side, id: String, name: String) -> some View {
        let settings = controller.settings
        let chosen = (side == .source ? settings.translationSource : settings.translationLanguage) == id
        return Button {
            choose(id, for: side)
        } label: {
            Text(name)
                .font(.system(size: 15, weight: chosen ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(chosen ? Palette.shellBottom : Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(chosen ? Palette.ink : Palette.shellTop, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // The text on view is translated again with the new language.
    private func choose(_ id: String, for side: Side) {
        switch side {
        case .source: controller.settings.translationSource = id
        case .target: controller.settings.translationLanguage = id
        }
        choosing = nil
        if let current = controller.translations.first {
            translate(current.original)
        }
    }

    // Languages iOS can translate into, by name.
    private static func targets() async -> [(id: String, name: String)] {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return supported
            .map { ($0.minimalIdentifier, Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier) }
            .filter { seen.insert($0.0).inserted }
            .sorted { $0.1 < $1.1 }
    }

    private func card(_ item: TranslatedText) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(languages(item))
                .font(.marking(13))
                .opacity(0.6)
            Text(item.original)
                .font(.system(size: 14))
                .opacity(0.6)
                .lineLimit(3)
            if let translation = item.translation {
                ScrollView {
                    Text(translation)
                        .font(.system(size: 21, weight: .medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            if let note = item.note {
                Text(note)
                    .font(.marking(14))
                    .opacity(0.8)
            }
            HStack(spacing: 10) {
                if let translation = item.translation {
                    smallButton("doc.on.clipboard", "Copy to Mac") { controller.sendText(translation) }
                } else if item.source != item.target, let url = google(item) {
                    Link(destination: url) { label("globe", "Google Translate") }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.groove, lineWidth: 2))
    }

    private var empty: some View {
        Text("Select text on the Mac and its translation shows here.")
            .font(.marking(16))
            .foregroundStyle(Palette.ink.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.groove, lineWidth: 2))
    }

    // For apps that keep their selection to themselves: copies it on the Mac
    // and puts the clipboard back.
    private var takeButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            smallButton("text.cursor", "Take selection") { controller.copySelection() }
            Text("If a selection does not show up by itself.")
                .font(.marking(12))
                .foregroundStyle(Palette.ink.opacity(0.6))
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // A tap puts an earlier translation on the Mac clipboard again.
                ForEach(controller.translations.dropFirst()) { item in
                    Button {
                        if let translation = item.translation { controller.sendText(translation) }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.original)
                                    .font(.system(size: 13))
                                    .opacity(0.6)
                                    .lineLimit(1)
                                Text(item.translation ?? item.note ?? "")
                                    .font(.system(size: 15))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if item.translation != nil {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 15, weight: .medium))
                                    .opacity(0.7)
                            }
                        }
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(item.translation == nil)
                }
            }
        }
    }

    private func smallButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(symbol, title) }
            .buttonStyle(.plain)
    }

    private func label(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.marking(14))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Palette.shellTop, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.groove, lineWidth: 2))
    }

    private func languages(_ item: TranslatedText) -> String {
        "\(item.source?.uppercased() ?? "?") → \(item.target.uppercased())"
    }

    private func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func google(_ item: TranslatedText) -> URL? {
        var components = URLComponents(string: "https://translate.google.com/")
        components?.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: item.target),
            URLQueryItem(name: "text", value: item.original),
            URLQueryItem(name: "op", value: "translate"),
        ]
        return components?.url
    }
}
