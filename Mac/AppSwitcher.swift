import AppKit

// Lists the Mac's apps with their windows for the phone, and brings one to
// the front. Windows are found through the accessibility API, which lets the
// companion raise a particular window, such as one of several in Chrome.
final class AppSwitcher {
    private let windowLimit = 12
    private let iconSize = 64.0
    private var icons: [String: Data] = [:]

    func apps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                RunningApp(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier ?? "",
                    name: app.localizedName ?? "",
                    active: app.isActive,
                    icon: icon(of: app),
                    windows: windows(of: app.processIdentifier).enumerated().prefix(windowLimit).compactMap { index, window in
                        guard let title = string(window, kAXTitleAttribute), !title.isEmpty else { return nil }
                        return RunningApp.Window(index: index, title: title, minimized: bool(window, kAXMinimizedAttribute))
                    }
                )
            }
    }

    func perform(_ command: AppCommand) {
        guard let app = NSRunningApplication(processIdentifier: command.pid) else { return }
        switch command.kind {
        case .activate:
            app.activate()
        case .quit:
            app.terminate()
        case .raiseWindow:
            guard let wanted = command.window else { return }
            let list = windows(of: command.pid)
            let byIndex = list.indices.contains(wanted.index) && string(list[wanted.index], kAXTitleAttribute) == wanted.title
            let match = byIndex ? list[wanted.index] : list.first { string($0, kAXTitleAttribute) == wanted.title }
            guard let match else { return }
            raise(match, of: app)
        }
    }

    // Like ⌘`: brings the front app's backmost window forward, so pressing it
    // again goes through all of them.
    func nextWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let list = windows(of: app.processIdentifier).filter { !bool($0, kAXMinimizedAttribute) }
        guard list.count > 1, let last = list.last else { return }
        raise(last, of: app)
    }

    private func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        if bool(window, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
    }

    private func windows(of pid: pid_t) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private func icon(of app: NSRunningApplication) -> Data? {
        let key = app.bundleIdentifier ?? app.localizedName ?? ""
        if let cached = icons[key] { return cached }
        guard let image = app.icon else { return nil }
        let size = NSSize(width: iconSize, height: iconSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(iconSize), pixelsHigh: Int(iconSize),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])
        icons[key] = png
        return png
    }
}

// A pulsing ring around the cursor for a moment, to find it on a big screen.
final class PointerFinder {
    private let size = 220.0
    private let duration = 1.6
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: TimeInterval = 0

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        startedAt = ProcessInfo.processInfo.systemUptime
        follow()
        panel.orderFrontRegardless()
        if let ring = panel.contentView?.layer?.sublayers?.first {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 2.2
            pulse.toValue = 0.35
            pulse.duration = 0.5
            pulse.repeatCount = 3
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(pulse, forKey: "pulse")
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard ProcessInfo.processInfo.systemUptime - startedAt < duration else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            return
        }
        follow()
    }

    private func follow() {
        let point = NSEvent.mouseLocation
        panel?.setFrameOrigin(NSPoint(x: point.x - size / 2, y: point.y - size / 2))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        let ring = CAShapeLayer()
        let inset = size * 0.3
        ring.frame = view.bounds
        ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: inset, dy: inset), transform: nil)
        ring.fillColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        ring.strokeColor = NSColor.systemRed.cgColor
        ring.lineWidth = 5
        view.layer?.addSublayer(ring)
        panel.contentView = view
        return panel
    }
}
