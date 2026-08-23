import AppKit

/// Transient on-screen toast confirming which tile fired. Also surfaces
/// app-min-size warnings ("can't go smaller than this") so a clamped tile
/// reads as an app limitation, not an app limitation. Non-activating: never steals
/// focus, so the next hotkey still targets the same frontmost window.
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, in screen: NSScreen? = nil) {
        DispatchQueue.main.async {
            hideWork?.cancel()
            panel?.orderOut(nil)
            panel = nil

            let targetScreen = screen ?? NSScreen.main
            guard let targetScreen else { return }

            let text = NSTextField(labelWithString: message)
            text.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            text.textColor = .white
            text.alignment = .center
            text.isEditable = false
            text.sizeToFit()

            let pad: CGFloat = 14
            let size = CGSize(width: text.frame.width + pad * 2, height: text.frame.height + pad * 1.5)
            let x = targetScreen.visibleFrame.midX - size.width / 2
            let y = targetScreen.visibleFrame.maxY - size.height - 60
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)

            let p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            box.material = .hudWindow
            box.state = .active
            box.wantsLayer = true
            box.layer?.cornerRadius = 10
            text.frame = NSRect(
                x: pad,
                y: (size.height - text.frame.height) / 2,
                width: text.frame.width,
                height: text.frame.height
            )
            box.addSubview(text)
            p.contentView = box

            panel = p
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1
            }
            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    p.animator().alphaValue = 0
                }, completionHandler: {
                    if panel === p { panel?.orderOut(nil); panel = nil }
                })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }
    }
}
