import AppKit

// The text selected on the Mac, for the phone's Translate page. Read through
// the accessibility API, a few times a second while the phone asks, so the
// clipboard stays untouched. Web pages keep their selection as a text marker
// range, which Safari and Chrome both answer.
final class SelectionReader {
    var send: ((String) -> Void)?

    static let lengthLimit = 2000

    private let interval = 0.3
    private let keepAlive = 5.0
    private let queue = DispatchQueue(label: "SwissKnife.selection")
    private let system = AXUIElementCreateSystemWide()
    private var requestedAt: TimeInterval = 0
    private var isRunning = false
    // Chrome and apps built on Electron build their accessibility tree only
    // for apps that ask, once per process.
    private var awakened: Set<pid_t> = []
    private var lastSeen = ""
    private var lastSent = ""

    init() {
        AXUIElementSetMessagingTimeout(system, 0.2)
    }

    // The phone repeats the request while the page is on view, and reading
    // stops when it stops asking.
    func request(_ on: Bool) {
        requestedAt = ProcessInfo.processInfo.systemUptime
        if on, !isRunning {
            isRunning = true
            lastSeen = ""
            lastSent = ""
            poll()
        } else if !on {
            isRunning = false
        }
    }

    func stop() {
        isRunning = false
    }

    // A selection goes out once it has held still for one look, so dragging
    // over a line does not send every step.
    private func poll() {
        guard isRunning, ProcessInfo.processInfo.systemUptime - requestedAt < keepAlive else {
            isRunning = false
            return
        }
        queue.async { [weak self] in
            let text = self?.read() ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if !text.isEmpty, text == self.lastSeen, text != self.lastSent {
                    self.lastSent = text
                    self.send?(text)
                }
                // Once the selection is gone, selecting the same words again
                // counts as new.
                if text.isEmpty {
                    self.lastSent = ""
                }
                self.lastSeen = text
                DispatchQueue.main.asyncAfter(deadline: .now() + self.interval) { self.poll() }
            }
        }
    }

    private func read() -> String {
        if let app = NSWorkspace.shared.frontmostApplication {
            awaken(app.processIdentifier)
        }
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return "" }
        let text = selectedText(focused) ?? markedText(focused) ?? ""
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.lengthLimit))
    }

    private func awaken(_ pid: pid_t) {
        guard !awakened.contains(pid) else { return }
        awakened.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private func selectedText(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private func markedText(_ element: AXUIElement) -> String? {
        var range: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, range, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
