import AppKit
import ApplicationServices

/// Moves the frontmost window of the active app using the Accessibility
/// (AXUIElement) API — the approach shared by Rectangle, Magnet and
/// yabai. Requires the app to be trusted in System Settings → Privacy &
/// Security → Accessibility.
///
/// Geometry is computed in AppKit cocoa rects (bottom-left, Y-up) against
/// `NSScreen.visibleFrame`. Conversion to/from AX (top-left, Y-down) happens
/// only at the read/write boundary.
final class WindowEngine {
    static let shared = WindowEngine()

    enum EngineError: LocalizedError {
        case notTrusted
        case noFrontWindow

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Glass needs Accessibility access to move windows."
            case .noFrontWindow:
                return "No movable window found."
            }
        }
    }

    /// Last cocoa frame snapshotted before a non-restore action.
    private var lastCocoaFrame: CGRect?

    private static func log(_ line: String) {
        let s = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = s.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/glass.log")
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try? h.seekToEnd()
                try? h.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// System dialog once per process. Hotkeys must never re-prompt.
    private static var promptedThisSession = false

    static func isTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return true }
        return AXIsProcessTrusted()
    }

    /// Explicit prompt (Settings button / first launch). Safe to call repeatedly;
    /// the system sheet is still only raised via `requestTrustIfNeeded` from hotkeys.
    static func requestTrust() {
        promptedThisSession = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestTrustIfNeeded() {
        guard !isTrusted(), !promptedThisSession else { return }
        requestTrust()
    }

    func perform(_ action: WindowAction) {
        // Do not gate on isTrusted(): AXIsProcessTrusted() is false for a stale
        // TCC row (old ad-hoc Glass) even when this .app is allowed. Prompting
        // on every hotkey is what the user saw. Try the move; prompt at most once
        // if AX cannot see a window.
        let trusted = Self.isTrusted()
        guard let window = frontWindow() else {
            Self.log("perform(\(action.rawValue)) no front window trusted=\(trusted)")
            Self.requestTrustIfNeeded()
            return
        }
        if !trusted {
            Self.log("perform(\(action.rawValue)) AX check false; trying anyway")
        }

        if action == .restore {
            if let saved = lastCocoaFrame {
                setCocoaFrame(window, saved)
            }
            return
        }

        guard let current = cocoaFrame(of: window) else {
            Self.requestTrustIfNeeded()
            return
        }
        lastCocoaFrame = current
        guard let screen = screen(for: current) else { return }
        setCocoaFrame(window, targetRect(for: action, current: current, screen: screen))
    }

    // MARK: - Front window

    /// Focused window of the frontmost application.
    private func frontWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef
        else { return nil }
        return (window as! AXUIElement)
    }

    // MARK: - Cocoa ↔ AX

    /// Top of the global desktop in AppKit coordinates.
    private var desktopHeight: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }

    private func axOrigin(forCocoa rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX, y: desktopHeight - rect.maxY)
    }

    private func cocoaRect(axOrigin origin: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: origin.x,
            y: desktopHeight - origin.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func cocoaFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return cocoaRect(axOrigin: origin, size: size)
    }

    /// Size → position → size. Electron (and some other apps) ignore a lone
    /// position write if the size does not yet fit the destination.
    private func setCocoaFrame(_ window: AXUIElement, _ rect: CGRect) {
        var origin = axOrigin(forCocoa: rect)
        var size = rect.size
        guard
            let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return }
        let s1 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let p1 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let s2 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if s1 != .success && p1 != .success && s2 != .success {
            Self.requestTrustIfNeeded()
        }
    }

    private func screen(for cocoaRect: CGRect) -> NSScreen? {
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    // MARK: - Layout

    /// Cocoa-space tile for `visible` (already the screen's visibleFrame) and `GlassSettings.gap`.
    /// Used by `perform` and by `--dump-layout` so e2e asserts the same math.
    func layoutRect(for action: WindowAction, current: CGRect, visible: CGRect, screen: NSScreen? = nil) -> CGRect {
        let area = visible.insetBy(dx: GlassSettings.gap, dy: GlassSettings.gap)
        let w = area.width
        let h = area.height
        let halfW = w / 2
        let halfH = h / 2
        let col = w / 3

        switch action {
        case .leftHalf:
            return CGRect(x: area.minX, y: area.minY, width: halfW, height: h)
        case .rightHalf:
            return CGRect(x: area.minX + halfW, y: area.minY, width: w - halfW, height: h)
        case .topHalf:
            return CGRect(x: area.minX, y: area.minY + halfH, width: w, height: h - halfH)
        case .bottomHalf:
            return CGRect(x: area.minX, y: area.minY, width: w, height: halfH)
        case .topLeft:
            return CGRect(x: area.minX, y: area.minY + halfH, width: halfW, height: h - halfH)
        case .topRight:
            return CGRect(x: area.minX + halfW, y: area.minY + halfH, width: w - halfW, height: h - halfH)
        case .bottomLeft:
            return CGRect(x: area.minX, y: area.minY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: area.minX + halfW, y: area.minY, width: w - halfW, height: halfH)
        case .leftThird:
            return CGRect(x: area.minX, y: area.minY, width: col, height: h)
        case .centerThird:
            return CGRect(x: area.minX + col, y: area.minY, width: col, height: h)
        case .rightThird:
            return CGRect(x: area.minX + 2 * col, y: area.minY, width: w - 2 * col, height: h)
        case .leftTwoThirds:
            return CGRect(x: area.minX, y: area.minY, width: w - col, height: h)
        case .rightTwoThirds:
            return CGRect(x: area.minX + col, y: area.minY, width: w - col, height: h)
        case .maximize:
            return area
        case .almostMaximize:
            return area.insetBy(dx: 50, dy: 50)
        case .center:
            return centered(current.size, in: visible)
        case .nextDisplay:
            guard let screen else { return current }
            return mapToAdjacentDisplay(current, from: screen, delta: 1)
        case .previousDisplay:
            guard let screen else { return current }
            return mapToAdjacentDisplay(current, from: screen, delta: -1)
        case .restore:
            return current
        }
    }

    private func targetRect(for action: WindowAction, current: CGRect, screen: NSScreen) -> CGRect {
        layoutRect(for: action, current: current, visible: screen.visibleFrame, screen: screen)
    }

    private func centered(_ size: CGSize, in bounds: CGRect) -> CGRect {
        var x = bounds.midX - size.width / 2
        var y = bounds.midY - size.height / 2
        if size.width <= bounds.width {
            x = min(max(x, bounds.minX), bounds.maxX - size.width)
        } else {
            x = bounds.minX
        }
        if size.height <= bounds.height {
            y = min(max(y, bounds.minY), bounds.maxY - size.height)
        } else {
            y = bounds.minY
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Preserve origin/size as fractions of `from.visibleFrame`, mapped onto
    /// the destination's visibleFrame. Screens cycle by frame.minX, then minY.
    private func mapToAdjacentDisplay(_ cocoaRect: CGRect, from screen: NSScreen, delta: Int) -> CGRect {
        let sorted = NSScreen.screens.sorted {
            ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY)
        }
        let count = sorted.count
        guard count > 0 else { return cocoaRect }
        let idx = sorted.firstIndex { $0.frame == screen.frame } ?? 0
        let next = sorted[(idx + delta % count + count) % count]
        let src = screen.visibleFrame
        let dst = next.visibleFrame
        guard src.width > 0, src.height > 0 else {
            return CGRect(origin: dst.origin, size: cocoaRect.size)
        }
        let fx = (cocoaRect.minX - src.minX) / src.width
        let fy = (cocoaRect.minY - src.minY) / src.height
        let fw = cocoaRect.width / src.width
        let fh = cocoaRect.height / src.height
        return CGRect(
            x: dst.minX + fx * dst.width,
            y: dst.minY + fy * dst.height,
            width: fw * dst.width,
            height: fh * dst.height
        )
    }
}
