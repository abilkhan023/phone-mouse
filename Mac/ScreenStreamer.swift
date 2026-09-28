import AppKit
import ScreenCaptureKit

// Small JPEG frames of the main display for the phone's mini screen, a few
// per second. A frame is taken only after the last one went out, so a slow
// link gets fewer frames instead of a growing queue.
final class ScreenStreamer {
    var send: ((Data, @escaping () -> Void) -> Void)?

    private let widthRange = 320...2560
    private let interval = 1.0 / 6
    private let quality = 0.75
    private var width = 1080
    private let keepAlive = 5.0
    private var isRunning = false
    private var requestedAt: TimeInterval = 0

    // The phone repeats the request while it watches; frames stop when it
    // stops asking. Frames come as wide as the phone's picture in pixels, so
    // text is as sharp as the phone can show it.
    func request(width: Int) {
        requestedAt = ProcessInfo.processInfo.systemUptime
        let on = width > 0
        if on {
            self.width = min(max(width, widthRange.lowerBound), widthRange.upperBound)
        }
        if on, !isRunning {
            isRunning = true
            capture()
        } else if !on {
            isRunning = false
        }
    }

    func stop() {
        isRunning = false
    }

    private func capture() {
        guard isRunning, ProcessInfo.processInfo.systemUptime - requestedAt < keepAlive else {
            isRunning = false
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        Task {
            let jpeg = await frame()
            await MainActor.run {
                let next = { [weak self] in
                    guard let self else { return }
                    let wait = max(0, self.interval - (ProcessInfo.processInfo.systemUptime - started))
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.capture() }
                }
                if let jpeg, let send = self.send {
                    send(jpeg, next)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.capture() }
                }
            }
        }
    }

    private func frame() async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = Int(Double(width) * Double(display.height) / Double(max(display.width, 1)))
        configuration.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
