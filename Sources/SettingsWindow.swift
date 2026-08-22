import AppKit
import ApplicationServices

// MARK: - Shortcut recorder (key-capture logic unchanged, keycap styling)

/// A control that records a global shortcut when the user presses keys.
final class ShortcutRecorderView: NSView {
    var onRecorded: ((Shortcut) -> Void)?
    private(set) var current: Shortcut?
    private let label = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyStyle(recording: false)

        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle(recording: Bool) {
        guard let layer else { return }
        layer.cornerRadius = 7
        if recording {
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
            layer.borderWidth = 1.5
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 7
            layer.shadowOffset = .zero
        } else {
            // Keycap: lit top edge, soft drop shadow below.
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            layer.borderWidth = 1
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.4
            layer.shadowRadius = 1.5
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
    }

    override func becomeFirstResponder() -> Bool {
        applyStyle(recording: true)
        label.textColor = .white
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        applyStyle(recording: false)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        return super.resignFirstResponder()
    }

    func setShortcut(_ shortcut: Shortcut?) {
        current = shortcut
        label.stringValue = shortcut?.displayString ?? "···"
        label.textColor = shortcut != nil
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.white.withAlphaComponent(0.32)
    }

    // MARK: Key capture

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

// MARK: - Compact action names for the grid

extension WindowAction {
    /// Tight label for the settings grid.
    var shortName: String {
        switch self {
        case .leftHalf: return "Left ½"
        case .rightHalf: return "Right ½"
        case .topHalf: return "Top ½"
        case .bottomHalf: return "Bottom ½"
        case .topLeft: return "Slide ←"
        case .topRight: return "Slide →"
        case .bottomLeft: return "Slide ↓"
        case .bottomRight: return "Slide ↑"
        case .leftThird: return "Third ◂"
        case .centerThird: return "Third ▪"
        case .rightThird: return "Third ▸"
        case .leftTwoThirds: return "⅔ Left"
        case .rightTwoThirds: return "⅔ Right"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Display ▸"
        case .previousDisplay: return "Display ◂"
        }
    }
}

// MARK: - Settings panel

/// Frosted, sectioned glass control panel.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private var recorders: [WindowAction: ShortcutRecorderView] = [:]
    private var accessChip: AccessChip?
    private var gapField: NSTextField?
    private var gapStepper: NSStepper?
    private var loginSwitch: NSSwitch?

    private static let gapRange = 0...40

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Glass — Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        loadShortcuts()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Builders

    private func captionLabel(_ text: String) -> NSTextField {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let attr = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.2,
            .paragraphStyle: para,
        ])
        let l = NSTextField(labelWithAttributedString: attr)
        return l
    }

    private func buildUI() {
        guard let window else { return }

        let effectView = NSVisualEffectView(frame: window.contentView!.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        window.contentView = effectView

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(content)

        // ── Header ──────────────────────────────────────────────────────
        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 10
        iconTile.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        iconTile.layer?.borderWidth = 1
        iconTile.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        let icon = NSTextField(labelWithString: "")
        if let base = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Glass")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) {
            let tinted = NSImage(size: base.size, flipped: false) { rect in
                NSColor.controlAccentColor.setFill()
                rect.fill()
                base.draw(in: rect)
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = tinted
            icon.attributedStringValue = NSAttributedString(attachment: attachment)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(icon)
        NSLayoutConstraint.activate([
            iconTile.widthAnchor.constraint(equalToConstant: 38),
            iconTile.heightAnchor.constraint(equalToConstant: 38),
            icon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
        ])

        let title = NSTextField(labelWithString: "Glass")
        title.font = .systemFont(ofSize: 21, weight: .bold)
        title.textColor = .labelColor
        let subtitle = NSTextField(labelWithString: "Window tiling · press a key cap to rebind")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleBlock = NSStackView(views: [title, subtitle])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 1

        accessChip = AccessChip(onGrant: #selector(grantTapped), target: self)
        refreshTrustStatus()

        let header = NSStackView(views: [iconTile, titleBlock, accessChip!])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            titleBlock.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        // ── Sections (scrollable) ───────────────────────────────────────
        let sections: [(String, [WindowAction])] = [
            ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
            ("Quarters · relative slide", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
            ("Thirds", [.leftThird, .centerThird, .rightThird]),
            ("Two thirds · Displays", [.leftTwoThirds, .rightTwoThirds, .previousDisplay, .nextDisplay]),
            ("Window", [.maximize, .almostMaximize, .center, .restore]),
        ]

        let sectionsStack = NSStackView()
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 16
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false

        for (caption, actions) in sections {
            sectionsStack.addArrangedSubview(captionLabel(caption))

            let cells = actions.map { makeCell(for: $0) }
            let grid = NSStackView(views: cells)
            grid.orientation = .horizontal
            grid.alignment = .top
            grid.distribution = .fillEqually
            grid.spacing = 8
            grid.translatesAutoresizingMaskIntoConstraints = false

            let card = GlassPanel(child: grid, insets: (12, 12, 12, 12))
            // Stretch every card to the full section width (stack alignment
            // alone is unreliable for custom views).
            card.setContentHuggingPriority(.defaultLow, for: .horizontal)
            sectionsStack.addArrangedSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: sectionsStack.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: sectionsStack.trailingAnchor),
            ])
        }

        // ── Controls strip ──────────────────────────────────────────────
        let gapCaption = captionLabel("Tiling gap")
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 40
        formatter.maximumFractionDigits = 0
        let field = NSTextField(string: "\(clampedGap(GlassSettings.gap))")
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.formatter = formatter
        field.target = self
        field.action = #selector(gapFieldChanged)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 40).isActive = true
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
        let px = NSTextField(labelWithString: "px")
        px.font = .systemFont(ofSize: 11)
        px.textColor = .tertiaryLabelColor

        let loginCaption = captionLabel("Launch at login")
        let loginToggle = NSSwitch()
        loginToggle.controlSize = .small
        loginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
        loginToggle.target = self
        loginToggle.action = #selector(launchAtLoginToggled(_:))
        loginToggle.toolTip = "Start Glass automatically when you sign in."
        loginSwitch = loginToggle

        let gapGroup = NSStackView(views: [gapCaption, field, stepper, px])
        gapGroup.orientation = .horizontal
        gapGroup.alignment = .centerY
        gapGroup.spacing = 7
        let loginGroup = NSStackView(views: [loginToggle, loginCaption])
        loginGroup.orientation = .horizontal
        loginGroup.alignment = .centerY
        loginGroup.spacing = 7

        let controls = GlassPanel(
            child: hstack([gapGroup, spacer(), loginGroup], spacing: 12),
            insets: (12, 12, 10, 10)
        )

        // ── Footer ──────────────────────────────────────────────────────
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let brand = NSTextField(labelWithString: "GLASS")
        let bAttr = NSAttributedString(string: "GLASS", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 2.0,
        ])
        brand.attributedStringValue = bAttr

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.toolTip = "Restore built-in shortcuts, gap and layout."

        let footer = hstack([brand, spacer(), reset], spacing: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false

        // ── Assemble ────────────────────────────────────────────────────
        let document = FlippedView(child: sectionsStack)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sectionsStack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document

        content.addSubview(scroll)
        content.addSubview(controls)
        content.addSubview(divider)
        content.addSubview(footer)
        // Autoresizing masks would otherwise inject required height=0 /
        // centering constraints that collapse the fixed bottom strip.
        controls.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            content.topAnchor.constraint(equalTo: effectView.topAnchor),
            content.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            // Design-size floor: without this, AppKit shrinks the window to
            // the content view's fitting size during layout.
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 720),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),

            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            controls.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -12),

            sectionsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            sectionsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            sectionsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            sectionsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func makeCell(for action: WindowAction) -> NSView {
        let label = NSTextField(labelWithString: action.shortName)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = action.displayName

        let recorder = ShortcutRecorderView(frame: .zero)
        recorder.setShortcut(ShortcutsStore.shared.shortcuts[action])
        recorder.toolTip = "Click, then press the new combo (\(action.displayName)). Esc cancels."
        recorder.onRecorded = { [weak self] shortcut in
            ShortcutsStore.shared.set(shortcut, for: action)
            HotKeyManager.shared.refresh()
            self?.sync()
        }
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let cell = NSStackView(views: [label, recorder])
        cell.orientation = .vertical
        cell.alignment = .centerX
        cell.spacing = 6
        cell.translatesAutoresizingMaskIntoConstraints = false
        recorders[action] = recorder
        return cell
    }

    private func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    // MARK: State

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

    // MARK: Actions

    @objc private func grantTapped() {
        refreshTrustStatus()
        guard !WindowEngine.isTrusted() else { return }  // already granted — never re-prompt
        // One click: raise the system consent prompt AND deep-link into the
        // Accessibility pane.
        WindowEngine.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshTrustStatus(after: 2)
    }

    private func refreshTrustStatus(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.accessChip?.setGranted(WindowEngine.isTrusted())
        }
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

    @objc private func launchAtLoginToggled(_ sender: NSSwitch) {
        if !LaunchAtLogin.setEnabled(sender.state == .on) {
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
}

// MARK: - Supporting views

/// Rounded frosted panel that wraps a child with insets.
final class GlassPanel: NSView {
    init(child: NSView, insets: (CGFloat, CGFloat, CGFloat, CGFloat)) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.0),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.1),
            child.topAnchor.constraint(equalTo: topAnchor, constant: insets.2),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Header status capsule: green "active" or amber "needs access" + grant button.
final class AccessChip: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let button: NSButton

    init(onGrant: Selector, target: AnyObject?) {
        button = NSButton(title: "Grant…", target: target, action: onGrant)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isHidden = true

        let row = NSStackView(views: [dot, label, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        setGranted(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setGranted(_ granted: Bool) {
        dot.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        label.stringValue = granted ? "Accessibility active" : "Accessibility needed"
        button.isHidden = granted
        invalidateIntrinsicContentSize()
    }
}

/// Top-origin document sized by its content, so the scroll view tiles
/// correctly even before the window is ever shown.
private final class FlippedView: NSView {
    private let child: NSView

    init(child: NSView) {
        self.child = child
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { child.fittingSize }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}
