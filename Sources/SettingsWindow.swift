import AppKit
import ApplicationServices

/// A control that records a global shortcut when the user presses keys.
final class ShortcutRecorderView: NSView {
    var onRecorded: ((Shortcut) -> Void)?
    private(set) var current: Shortcut?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let label = NSTextField(labelWithString: "Press shortcut…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.tag = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setShortcut(_ shortcut: Shortcut?) {
        current = shortcut
        let label = viewWithTag(1) as? NSTextField
        label?.stringValue = shortcut?.displayString ?? "Press shortcut…"
        label?.font = shortcut != nil ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
    }

    // MARK: - Key capture

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc cancels
            setShortcut(current)
            return
        }
        guard let mods = Shortcut.modifiers(from: event) else {
            NSSound.beep()
            return
        }
        let shortcut = Shortcut(keyCode: event.keyCode, modifiers: mods)
        setShortcut(shortcut)
        onRecorded?(shortcut)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

extension Shortcut {
    /// Modifiers suitable for a global shortcut (excludes function keys etc.).
    static func modifiers(from event: NSEvent) -> NSEvent.ModifierFlags? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Require at least one real modifier.
        return flags.isEmpty ? nil : flags
    }
}

/// The glass settings window: translucent material, rounded glass card.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private var recorders: [WindowAction: ShortcutRecorderView] = [:]
    private var axStatus: NSTextField?
    private var grantButton: NSButton?
    private var showPromptButton: NSButton?
    private var gapField: NSTextField?
    private var gapStepper: NSStepper?

    private static let gapRange = 0...40

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Glass — Shortcuts"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        super.init(window: window)
        buildUI()
        loadShortcuts()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func grantTapped() {
        refreshTrustStatus()
        guard !WindowEngine.isTrusted() else { return }  // already granted — never re-prompt
        // One click: raise the system consent prompt (it has its own “Open
        // System Settings” button) AND deep-link straight into the
        // Accessibility pane, so the user never has to hunt for it.
        WindowEngine.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshTrustStatus(after: 2)
    }

    private func refreshTrustStatus(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let label = self.axStatus else { return }
            let button = self.grantButton
            let prompt = self.showPromptButton
            if WindowEngine.isTrusted() {
                label.stringValue = "Granted — Glass can move windows ✓"
                label.textColor = .systemGreen
                button?.isEnabled = false
                button?.title = "Granted"
                prompt?.isEnabled = false
            } else {
                label.stringValue = "Not granted yet — allow Glass in System Settings"
                label.textColor = .systemOrange
                button?.isEnabled = true
                button?.title = "Grant Access…"
                prompt?.isEnabled = true
            }
        }
    }

    private func buildUI() {
        guard let window else { return }

        // Full-bleed vibrancy: the classic glass look.
        let effectView = NSVisualEffectView(frame: window.contentView!.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        window.contentView = effectView

        // Title — compact header: tight, hierarchical, tooltip carries detail.
        let title = NSTextField(labelWithString: "Shortcuts")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = NSColor.labelColor
        title.toolTip = "Global shortcuts tile the frontmost window of any app."
        let subtitle = NSTextField(labelWithString: "Click a shortcut, then press the keys you want to bind. Esc resets.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.toolTip = "Shortcuts need at least one of ⌘, ⌥ or ⌃."

        let titleBlock = NSStackView(views: [title, subtitle])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .centerX
        titleBlock.spacing = 2

        // Accessibility gate — one click, no manual Settings spelunking.
        let axStatusLabel = NSTextField(labelWithString: "")
        axStatusLabel.font = .systemFont(ofSize: 11)
        axStatusLabel.lineBreakMode = .byTruncatingTail
        axStatusLabel.toolTip = "Glass moves other apps' windows via the Accessibility API."
        axStatus = axStatusLabel
        let grantButton = NSButton(title: "Grant Access…", target: self, action: #selector(grantTapped))
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        grantButton.toolTip = "Opens System Settings → Privacy & Security → Accessibility for Glass."
        self.grantButton = grantButton
        let axRow = NSStackView(views: [axStatusLabel, grantButton])
        axRow.orientation = .horizontal
        axRow.spacing = 10

        let gapRow = makeGapRow()

        let header = NSStackView(views: [titleBlock, axRow, gapRow])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setContentHuggingPriority(.required, for: .vertical)
        refreshTrustStatus()

        // One glass row per action, inside a scroll view (19 actions won't fit).
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // Two shortcut cells per line, centered (compact grid, not full-width rows).
        var pair: [NSView] = []
        for action in WindowAction.allCases {
            pair.append(makeRow(for: action))
            if pair.count == 2 {
                let line = NSStackView(views: pair)
                line.orientation = .horizontal
                line.alignment = .centerY
                line.spacing = 8
                line.translatesAutoresizingMaskIntoConstraints = false
                rowsStack.addArrangedSubview(line)
                pair = []
            }
        }
        if !pair.isEmpty {
            let line = NSStackView(views: pair)
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
            line.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(line)
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // Footer: settings on the left, actions right-aligned.
        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetTapped))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "Restore the built-in default shortcuts for every action."

        let showButton = NSButton(title: "Grant Access…", target: self, action: #selector(trustTapped))
        showButton.bezelStyle = .rounded
        showButton.controlSize = .small
        showButton.toolTip = "Shows the macOS prompt that grants Glass Accessibility access."
        showButton.isEnabled = !WindowEngine.isTrusted()
        showPromptButton = showButton

        let loginCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: self,
            action: #selector(launchAtLoginToggled(_:))
        )
        loginCheckbox.font = .systemFont(ofSize: 12)
        loginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        loginCheckbox.toolTip = "Start Glass automatically when you sign in to your Mac."
        loginCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        let actions = NSStackView(views: [resetButton, showButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let footer = NSStackView(views: [loginCheckbox, spacer, actions])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setContentHuggingPriority(.required, for: .vertical)

        let container = NSStackView(views: [header, scroll, footer])
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),
            container.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 24),
            container.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -16),
        ])
    }

    private func makeGapRow() -> NSView {
        let label = NSTextField(labelWithString: "Gap")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.labelColor

        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 40
        formatter.maximumFractionDigits = 0

        let field = NSTextField(string: "\(clampedGap(GlassSettings.gap))")
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.formatter = formatter
        field.target = self
        field.action = #selector(gapFieldChanged)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        gapField = field

        let stepper = NSStepper()
        stepper.minValue = Double(Self.gapRange.lowerBound)
        stepper.maxValue = Double(Self.gapRange.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = clampedGap(GlassSettings.gap)
        stepper.target = self
        stepper.action = #selector(gapStepperChanged)
        gapStepper = stepper

        let row = NSStackView(views: [label, field, stepper])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeRow(for action: WindowAction) -> NSView {
        let label = NSTextField(labelWithString: action.displayName)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.labelColor
        label.alignment = .center
        label.toolTip = "Shortcut that tiles the frontmost window."

        let recorder = ShortcutRecorderView(frame: .zero)
        recorder.setShortcut(ShortcutsStore.shared.shortcuts[action])
        recorder.toolTip = "Click, then press a new combo (needs ⌘, ⌥ or ⌃). Esc resets."
        recorder.onRecorded = { [weak self] shortcut in
            ShortcutsStore.shared.set(shortcut, for: action)
            HotKeyManager.shared.refresh()
            self?.sync()
        }
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 132).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true

        // Compact centered cell: name on top, shortcut pill below.
        let cell = NSStackView(views: [label, recorder])
        cell.orientation = .vertical
        cell.alignment = .centerX
        cell.spacing = 6
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let glass = GlassCard(row: cell)
        recorders[action] = recorder
        return glass
    }

    private func loadShortcuts() { sync() }

    private func sync() {
        let shortcuts = ShortcutsStore.shared.shortcuts
        for action in WindowAction.allCases {
            recorders[action]?.setShortcut(shortcuts[action])
        }
        syncGap()
    }

    private func syncGap() {
        let value = clampedGap(GlassSettings.gap)
        gapField?.integerValue = value
        gapStepper?.integerValue = value
    }

    private func clampedGap(_ value: CGFloat) -> Int {
        min(Self.gapRange.upperBound, max(Self.gapRange.lowerBound, Int(value.rounded())))
    }

    private func applyGap(_ value: Int) {
        let clamped = min(Self.gapRange.upperBound, max(Self.gapRange.lowerBound, value))
        GlassSettings.gap = CGFloat(clamped)
        syncGap()
    }

    @objc private func gapStepperChanged(_ sender: NSStepper) {
        applyGap(sender.integerValue)
    }

    @objc private func gapFieldChanged(_ sender: NSTextField) {
        applyGap(sender.integerValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === gapField else { return }
        applyGap(gapField?.integerValue ?? 0)
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let wantEnabled = sender.state == .on
        if !LaunchAtLogin.setEnabled(wantEnabled) {
            NSSound.beep()
            sender.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    @objc private func resetTapped() {
        ShortcutsStore.shared.resetToDefaults()
        GlassSettings.gap = 0
        HotKeyManager.shared.refresh()
        sync()
    }

    @objc private func trustTapped() {
        WindowEngine.requestTrust()
    }
}

/// A rounded translucent card that gives each row a "glass" feel.
final class GlassCard: NSView {
    init(row: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Top-origin document so shortcut rows start at the top of the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
