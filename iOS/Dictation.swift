import AVFoundation
import Observation
import Speech

// Speech to text on the phone. Each update carries the whole text heard so
// far in this session; the recognizer may still revise its last words.
@Observable
final class Dictation {
    enum Problem: Equatable {
        case denied
        case unavailable
    }

    private(set) var isListening = false
    private(set) var text = ""
    private(set) var problem: Problem?

    @ObservationIgnored var onText: ((String) -> Void)?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    // Text from earlier recognition rounds; a round ends after a pause or a
    // minute, and listening goes on in a new one.
    @ObservationIgnored private var committed = ""

    // Languages offered in settings, if the phone can recognize them.
    static var languages: [(id: String, name: String)] {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        return ["ru-RU", "en-US", "kk-KZ", "de-DE", "fr-FR", "es-ES", "tr-TR", "uk-UA"]
            .filter { supported.contains($0) || supported.contains($0.replacingOccurrences(of: "-", with: "_")) }
            .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
    }

    func start(language: String) {
        guard !isListening else { return }
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else {
                        self.problem = .denied
                        return
                    }
                    self.begin(language: language)
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func begin(language: String) {
        let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            problem = .unavailable
            return
        }
        self.recognizer = recognizer
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
        } catch {
            problem = .unavailable
            return
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = .unavailable
            return
        }
        text = ""
        committed = ""
        isListening = true
        round()
    }

    private func round() {
        guard isListening, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                if let result {
                    let heard = result.bestTranscription.formattedString
                    self.update(self.join(self.committed, heard))
                    if result.isFinal {
                        self.committed = self.text
                    }
                }
                if result?.isFinal == true {
                    self.round()
                } else if error != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.round() }
                }
            }
        }
    }

    private func join(_ earlier: String, _ next: String) -> String {
        guard !earlier.isEmpty, !next.isEmpty else { return earlier + next }
        return earlier + " " + next
    }

    private func update(_ full: String) {
        guard full != text else { return }
        text = full
        onText?(full)
    }
}
