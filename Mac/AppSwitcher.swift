import AppKit
import OSLog

// Lists the Mac's apps with their windows for the phone, and brings one to
// the front. Windows are found through the accessibility API, which lets the
// companion raise a particular window, such as one of several in Chrome.
final class AppSwitcher {
    private let windowLimit = 12
    private let tabLimit = 40
    private let iconSize = 64.0
    private var icons: [String: Data] = [:]

    func apps() -> [RunningApp] {
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                let windows = windows(of: app.processIdentifier).enumerated().prefix(windowLimit).compactMap { index, window in
                    guard let title = string(window, kAXTitleAttribute), !title.isEmpty else { return nil }
                    return RunningApp.Window(index: index, title: title, minimized: bool(window, kAXMinimizedAttribute))
                } as [RunningApp.Window]
                return RunningApp(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier ?? "",
                    name: app.localizedName ?? "",
                    active: app.isActive,
                    icon: icon(of: app),
                    windows: withTabs(windows, of: app)
                )
            }
    }

    // A browser's windows get their tabs. The browser names a window after
    // its current tab, as the accessibility title does, which pairs the two
    // up; windows it knows that are out of sight come last.
    private func withTabs(_ windows: [RunningApp.Window], of app: NSRunningApplication) -> [RunningApp.Window] {
        guard let bundleID = app.bundleIdentifier, let scripted = BrowserTabs.windows(of: bundleID) else { return windows }
        var remaining = scripted
        var result = windows.map { window in
            var window = window
            if let found = remaining.firstIndex(where: { window.title == $0.name || window.title.hasPrefix($0.name + " - ") }) {
                let browser = remaining.remove(at: found)
                window.browserID = browser.id
                window.tabs = browser.list(limit: tabLimit)
            }
            return window
        }
        for browser in remaining.prefix(max(windowLimit - result.count, 0)) where !browser.name.isEmpty {
            result.append(RunningApp.Window(index: -1, title: browser.name, minimized: false, browserID: browser.id, tabs: browser.list(limit: tabLimit)))
        }
        return result
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
        case .selectTab:
            guard let bundleID = app.bundleIdentifier, let id = command.window?.browserID, let tab = command.tab else { return }
            BrowserTabs.select(tab: tab, window: id, of: bundleID)
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

// Tabs come from the browsers through their scripting, which the
// accessibility API does not reach. macOS asks once before the companion may
// script each browser. The scripts run as a separate process and wait for the
// browser, so callers stay off the main thread.
enum BrowserTabs {
    struct Window: Decodable {
        let id: Int
        let name: String
        let active: Int
        let tabs: [String]

        func list(limit: Int) -> [RunningApp.Tab] {
            tabs.prefix(limit).enumerated().map { offset, title in
                RunningApp.Tab(index: offset + 1, title: title, active: offset + 1 == active)
            }
        }
    }

    private static let log = Logger(subsystem: "dev.phonemouse.PhoneMouseHost", category: "tabs")
    private static let chromium: Set = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]
    private static let safari: Set = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    private static let listScript = """
    function run(argv) {
      const app = Application(argv[0]);
      const chromium = argv[1] === 'chromium';
      return JSON.stringify(app.windows().flatMap(w => {
        try {
          const tabs = chromium ? w.tabs.title() : w.tabs.name();
          const active = chromium ? w.activeTabIndex() : w.currentTab.index();
          return [{ id: Number(w.id()), name: w.name(), active: active, tabs: tabs }];
        } catch (e) {
          return [];
        }
      }));
    }
    """

    private static let selectScript = """
    function run(argv) {
      const app = Application(argv[0]);
      // Chrome gives window ids as text, Safari as numbers.
      const w = app.windows.byId(argv[1] === 'chromium' ? argv[2] : Number(argv[2]));
      const tab = Number(argv[3]);
      if (argv[1] === 'chromium') {
        w.activeTabIndex = tab;
      } else {
        w.currentTab = w.tabs[tab - 1];
      }
      w.index = 1;
      app.activate();
    }
    """

    static func windows(of bundleID: String) -> [Window]? {
        guard let family = family(of: bundleID),
              let output = run(listScript, [bundleID, family]) else { return nil }
        do {
            return try JSONDecoder().decode([Window].self, from: output)
        } catch {
            log.error("Tabs of \(bundleID, privacy: .public) unreadable: \(error, privacy: .public)")
            return nil
        }
    }

    static func select(tab: Int, window: Int, of bundleID: String) {
        guard let family = family(of: bundleID) else { return }
        run(selectScript, [bundleID, family, String(window), String(tab)])
    }

    private static func family(of bundleID: String) -> String? {
        if chromium.contains(bundleID) { return "chromium" }
        if safari.contains(bundleID) { return "safari" }
        return nil
    }

    @discardableResult
    private static func run(_ script: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            log.error("Browser script for \(arguments.first ?? "", privacy: .public) failed: \(String(decoding: failure, as: UTF8.self), privacy: .public)")
            return nil
        }
        return output
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
