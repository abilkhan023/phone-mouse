import AppKit
import IOKit.pwr_mgt

// Types the Mac's password into the lock screen for the phone. The password
// comes from the phone each time and is kept nowhere here. It is typed only
// while the screen is locked, so it can never land in an open document.
final class ScreenUnlocker {
    private let wakeDelay = 0.8
    private let checkDelay = 2.5
    private var busy = false

    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func unlock(password: String, keyboard: KeyboardDriver, done: @escaping (UnlockOutcome) -> Void) {
        guard !busy else { return }
        guard Self.isLocked else {
            done(.notLocked)
            return
        }
        busy = true
        wake()
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeDelay) { [weak self] in
            guard let self else { return }
            // Checked again: the screen may have been unlocked meanwhile.
            if Self.isLocked {
                keyboard.apply(KeyEvent(seq: 0, kind: .text, text: password))
                keyboard.apply(KeyEvent(seq: 0, kind: .enter))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.checkDelay) {
                self.busy = false
                done(Self.isLocked ? .stillLocked : .unlocked)
            }
        }
    }

    // The same as a touch of the mouse: turns the display on and brings up
    // the password field.
    private func wake() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Phone Mouse unlock" as CFString, kIOPMUserActiveLocal, &assertion)
        IOPMAssertionRelease(assertion)
    }
}
