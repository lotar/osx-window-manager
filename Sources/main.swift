import AppKit
import Foundation

/// CLI used by e2e: math dump (no AX) or one-shot tile (needs AX).
/// `Glass --dump-layout vx vy vw vh [cx cy cw ch]` prints JSON of every action's cocoa rect.
/// `Glass --action leftHalf` tiles the frontmost focused window and exits.
private func runCLI() -> Bool {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--dump-layout"), i + 4 < args.count {
        func num(_ s: String) -> CGFloat { CGFloat(Double(s) ?? 0) }
        let vis = CGRect(x: num(args[i + 1]), y: num(args[i + 2]), width: num(args[i + 3]), height: num(args[i + 4]))
        var current = vis
        if i + 8 < args.count {
            current = CGRect(x: num(args[i + 5]), y: num(args[i + 6]), width: num(args[i + 7]), height: num(args[i + 8]))
        }
        var obj: [String: [String: Double]] = [:]
        for action in WindowAction.allCases {
            let r = WindowEngine.shared.layoutRect(for: action, current: current, visible: vis)
            obj[action.rawValue] = ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return true
    }
    if let i = args.firstIndex(of: "--action"), i + 1 < args.count {
        guard let action = WindowAction(rawValue: args[i + 1]) else {
            fputs("unknown action \(args[i + 1])\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if !WindowEngine.isTrusted() {
            fputs("not-trusted\n", stderr)
            exit(3)
        }
        WindowEngine.shared.perform(action)
        Thread.sleep(forTimeInterval: 0.35)
        return true
    }
    if let i = args.firstIndex(of: "--dump-resolve"), i + 8 < args.count {
        // Matrix driver: for a given current rect + visible frame, print every
        // action's resolved action and target cocoa rect.
        // Optional 9th/10th args = an app-min clamped actual size, which adds
        // pinnedRect(target, actualSize) to the output.
        func num(_ s: String) -> CGFloat { CGFloat(Double(s) ?? 0) }
        let current = CGRect(x: num(args[i + 1]), y: num(args[i + 2]), width: num(args[i + 3]), height: num(args[i + 4]))
        let vis = CGRect(x: num(args[i + 5]), y: num(args[i + 6]), width: num(args[i + 7]), height: num(args[i + 8]))
        let clampSize: CGSize? = i + 10 < args.count
            ? CGSize(width: num(args[i + 9]), height: num(args[i + 10]))
            : nil
        var obj: [String: [String: Double]] = [:]
        for action in WindowAction.allCases {
            let resolved = WindowEngine.shared.resolvedAction(for: action, current: current, visible: vis)
            var target = WindowEngine.shared.layoutRect(for: resolved, current: current, visible: vis)
            if let clampSize {
                target = WindowEngine.pinnedRect(target: target, actualSize: clampSize, action: resolved)
            }
            obj["\(action.rawValue)=>\(resolved.rawValue)"] = [
                "x": target.minX, "y": target.minY, "w": target.width, "h": target.height,
                "cx": target.midX, "cy": target.midY,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return true
    }
    if let i = args.firstIndex(of: "--roundtrip") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if !WindowEngine.isTrusted() {
            fputs("not-trusted\n", stderr)
            exit(3)
        }
        // Optional action argument; default topHalf (exercises the Y flip).
        let actionName = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "topHalf"
        guard let action = WindowAction(rawValue: actionName) else {
            fputs("unknown action \(actionName)\n", stderr)
            exit(2)
        }
        if let report = WindowEngine.shared.debugRoundTrip(action: action) {
            print(report)
        } else {
            fputs("no-front-window\n", stderr)
            exit(4)
        }
        return true
    }
    if args.contains("--trusted") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        print(WindowEngine.isTrusted() ? "1" : "0")
        return true
    }
    return false
}

if runCLI() {
    exit(0)
}

/// Debug bridge: lets an untrusted shell (e2e, developer) ask the trusted,
/// running Glass to execute a geometry round-trip on the front window.
/// Trigger:  printf topLeft > /tmp/glass-roundtrip.action
///           notifyutil -p glass.debug.roundtrip
/// Report:   /tmp/glass-roundtrip.log
enum RoundTripDebug {
    static let notifyName = "glass.debug.roundtrip" as CFString
    static let actionFile = "/tmp/glass-roundtrip.action"
    static let pidFile = "/tmp/glass-roundtrip.pid"
    static let reportFile = "/tmp/glass-roundtrip.log"

    static func install() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in DispatchQueue.main.async { RoundTripDebug.run() } },
            notifyName,
            nil,
            .deliverImmediately
        )
    }

    static func run() {
        let requested = (try? String(contentsOfFile: actionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let action = WindowAction(rawValue: requested) ?? .topHalf
        let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let seq = (try? String(contentsOfFile: "/tmp/glass-roundtrip.seq", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let report = WindowEngine.shared.debugRoundTrip(action: action, targetPID: pid) ?? "no-front-window"
        try? "seq=\(seq) action=\(requested)\n\(report)".write(toFile: reportFile, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app (LSUIElement in Info.plist).
        setupStatusItem()

        // One consent sheet at most. Hotkeys never raise it again this process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WindowEngine.requestTrustIfNeeded()
        }

        // Register the global shortcuts (Carbon hotkeys, like Rectangle/Magnet).
        HotKeyManager.shared.install { action in
            WindowEngine.shared.perform(action)
        }

        RoundTripDebug.install()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutsDidChange),
            name: Notification.Name("glass.shortcuts.didChange"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Glass")
            button.toolTip = "Glass — window manager"
        }
        self.statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())

        let actionsSection = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        menu.addItem(actionsSection)

        for action in WindowAction.allCases {
            let title = action.displayName
            let sc = ShortcutsStore.shared.shortcuts[action]?.displayString
            let item = menu.addItem(withTitle: sc != nil ? "\(title)  \(sc!)" : title,
                                    action: #selector(runAction(_:)),
                                    keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            item.indentationLevel = 1
        }

        menu.addItem(.separator())
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glass", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }

    @objc private func shortcutsDidChange() {
        rebuildStatusMenu()
    }

    @objc private func screensDidChange() {
        HotKeyManager.shared.refresh()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let wantEnabled = sender.state != .on
        _ = LaunchAtLogin.setEnabled(wantEnabled)
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = WindowAction(rawValue: raw) else { return }
        WindowEngine.shared.perform(action)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
