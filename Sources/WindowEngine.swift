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
                return "osx-window-manager needs Accessibility access to move windows."
            case .noFrontWindow:
                return "No movable window found."
            }
        }
    }

    /// Last cocoa frame snapshotted before a non-restore action.
    private var lastCocoaFrame: CGRect?

    /// Incremented on every perform(); in-flight animations and settle/
    /// repin callbacks from a previous move abort when superseded, so rapid
    /// keypresses can't corrupt each other.
    private var moveGeneration = 0

    private static func log(_ line: String) {
        let s = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = s.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/owm.log")
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

    /// Hotkey-level logging (modifier delivery diagnostics).
    static func logForHotKeys(_ line: String) {
        log(line)
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

    // MARK: - Animation (configurable; 0.4s default, 0 = instant)

    static let animationDurationKey = "osx-window-manager.animation.v1"

    /// Duration in seconds for animated window moves (persisted in UserDefaults).
    static var animationDuration: Double {
        get { UserDefaults.standard.object(forKey: animationDurationKey) as? Double ?? 0.4 }
        set {
            let clamped = min(max(newValue, 0), 2)
            UserDefaults.standard.set(clamped, forKey: animationDurationKey)
        }
    }

    /// Sets the AX position + size immediately (used for discrete jumps and
    /// the last frame of an animation).
    func moveImmediate(_ window: AXUIElement, to cocoaFrame: CGRect) {
        var origin = Self.quartzOrigin(ofCocoa: cocoaFrame) // Cocoa → Quartz global
        var size = cocoaFrame.size
        if let o = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, o)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        }
    }

    /// Animates the window from its current frame to `target` over
    /// `Self.animationDuration` (ease-out). Callers must have snapshotted the
    /// source frame before any move.
    func moveAnimated(_ window: AXUIElement, from source: CGRect, to target: CGRect, generation: Int? = nil) {
        let duration = Self.animationDuration
        guard duration > 0, source != target else {
            moveImmediate(window, to: target)
            return
        }
        let start = Date().timeIntervalSinceReferenceDate
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { t in
            // A newer move supersedes this animation.
            if let generation, generation != self.moveGeneration { t.invalidate(); return }
            let elapsed = Date().timeIntervalSinceReferenceDate - start
            let x = min(max(elapsed / duration, 0), 1)
            let ease = 1 - pow(1 - x, 3) // easeOutCubic
            var p = CGPoint(
                x: source.minX + (target.minX - source.minX) * ease,
                y: source.minY + (target.minY - source.minY) * ease
            )
            var s = CGSize(
                width: source.width + (target.width - source.width) * ease,
                height: source.height + (target.height - source.height) * ease
            )
            // Interpolated p is Cocoa; convert with the shared helper.
            var origin = Self.quartzOrigin(ofCocoa: CGRect(origin: p, size: s))
            if let ov = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, ov)
            }
            if let sv = AXValueCreate(.cgSize, &s) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
            }
            if x >= 1 {
                t.invalidate()
                if let generation, generation != self.moveGeneration { return }
                // Snap to the exact target so the final frame is pixel-precise.
                self.moveImmediate(window, to: target)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func perform(_ action: WindowAction) {
        // Do not gate on isTrusted(): AXIsProcessTrusted() is false for a stale
        // TCC row (old ad-hoc build) even when this .app is allowed. Prompting
        // on every hotkey is what the user saw. Try the move; prompt at most once
        // if AX cannot see a window.
        moveGeneration += 1
        let generation = moveGeneration
        let trusted = Self.isTrusted()
        Self.log("perform(\(action.rawValue)) animDur=\(String(format: "%.2f", Self.animationDuration))s trusted=\(trusted)")
        guard let window = frontWindow() else {
            Self.log("perform(\(action.rawValue)) no front window trusted=\(trusted)")
            Self.requestTrustIfNeeded()
            return
        }
        if !trusted {
            Self.log("perform(\(action.rawValue)) AX check false; trying anyway")
        }

        guard let current = cocoaFrame(of: window) else {
            Self.requestTrustIfNeeded()
            return
        }
        if action == .restore {
            if let saved = lastCocoaFrame {
                moveAnimated(window, from: current, to: saved)
            }
            return
        }
        guard let screen = screen(for: current) else { return }
        let resolved = resolvedAction(for: action, current: current, visible: screen.visibleFrame)
        var target = targetRect(for: resolved, current: current, screen: screen)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        // Probe the size the app will actually accept (many enforce a minimum
        // window size) BEFORE animating, and pin the animation target to the
        // achievable on-screen rect. Only needed when shrinking; grows are
        // effectively never clamped, so skip the latency there.
        var clampedTo: CGSize?
        if target.width < current.width - 0.5 || target.height < current.height - 0.5 {
            // Probe axes INDEPENDENTLY. Asking for the full target when one
            // axis is below the app's minimum makes some apps return garbage
            // on BOTH axes (WhatsApp: ask 1728x497, get 1701x600, and the
            // width creeps toward 1728 only over repeated presses). Height
            // first (keeping current width), then width at the accepted
            // height. Probe origins are clamped so test writes stay on-screen.
            func probeOrigin(_ size: CGSize) -> CGPoint {
                let vf = screen.visibleFrame
                return CGPoint(
                    x: min(max(current.origin.x, vf.minX), vf.maxX - size.width),
                    y: min(max(current.origin.y, vf.minY), vf.maxY - size.height)
                )
            }
            var size = current.size
            // Writes `wanted` and returns the size the app actually accepted.
            // Electron apps (WhatsApp) often DROP a resize write that lands
            // while they are still processing the previous one, so a single
            // write is not trustworthy - retry until the frame reflects the
            // write, the app clamps to its own minimum (responded, won't go
            // further), or attempts run out.
            func acceptedSize(_ wanted: CGSize) -> CGSize {
                let before = cocoaFrame(of: window) ?? CGRect(origin: .zero, size: wanted)
                for _ in 0..<4 {
                    moveImmediate(window, to: CGRect(origin: probeOrigin(wanted), size: wanted))
                    if let p = settledFrame(of: window, tries: 4, interval: 0.05) {
                        if abs(p.size.width - wanted.width) <= 0.5 && abs(p.size.height - wanted.height) <= 0.5 {
                            return p.size
                        }
                        if p.size != before.size {
                            return p.size // responded but clamped to its own minimum
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.12)
                }
                return (settledFrame(of: window) ?? before).size
            }
            if target.height < current.height - 0.5 {
                size = acceptedSize(CGSize(width: current.width, height: target.height))
            }
            if target.width < current.width - 0.5 {
                size = acceptedSize(CGSize(width: target.width, height: size.height))
            }
            if abs(size.width - target.width) > 0.5 || abs(size.height - target.height) > 0.5 {
                Self.log("perform(\(action.rawValue)) probe clamp \(target.size) -> \(size) app=\(appName)")
                clampedTo = size
                target = Self.pinnedRect(target: target, actualSize: size, action: resolved)
            }
        }

        lastCocoaFrame = current
        Self.log("perform(\(action.rawValue)) resolved=\(resolved.rawValue) app=\(appName) current=\(current) screen='\(screen.localizedName)' visible=\(screen.visibleFrame) mainH=\(Self.mainScreenHeight()) target=\(target)")
        if let minSize = clampedTo {
            HUD.show("\(resolved.displayName)\n⚠︎ \(appName) min size \(Int(minSize.width))×\(Int(minSize.height))", in: screen)
        } else {
            HUD.show(resolved.displayName, in: screen)
        }
        moveAnimated(window, from: current, to: target, generation: generation)
        // Safety net: if the app still clamped late, re-pin (no-op normally).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration + 0.1) { [weak self] in
            guard let self, generation == self.moveGeneration else { return }
            self.settleAndRepin(window, target: target, action: resolved)
            if let after = self.cocoaFrame(of: window) {
                Self.log("perform(\(action.rawValue)) finalRead=\(after) delta=\(CGSize(width: after.minX - target.minX, height: after.minY - target.minY))")
            }
        }
    }

    /// Directional resolution shared by hotkeys and the debug bridge.
    /// - Shifted arrows slide RELATIVELY on the 2x2 quarter grid: ←/→ one
    ///   column, ↑/↓ one row — CLAMPED to the screen, so pressing further
    ///   past an edge is a no-op (no wrapping).
    /// - All other tiles are ordered along their axis (halves, thirds,
    ///   two-thirds): picking a tile always moves toward it, can never leave
    ///   the screen, and re-picking the tile you're in is a no-op.
    func resolvedAction(for action: WindowAction, current: CGRect, visible: CGRect) -> WindowAction {
        guard isCorner(action) else { return action }
        let (dCol, dRow): (Int, Int)
        switch action {
        case .topLeft: (dCol, dRow) = (-1, 0)    // ←
        case .topRight: (dCol, dRow) = (1, 0)    // →
        case .bottomLeft: (dCol, dRow) = (0, -1) // ↓
        default: (dCol, dRow) = (0, 1)           // ↑
        }
        // Deterministic tie-breaks for windows SPANNING the center (halves,
        // maximized): a ±1pt rounding artifact of the tiled app must not flip
        // the target quadrant. Horizontal slides land in the top row, vertical
        // slides in the left column.
        let col: Int
        if abs(current.midX - visible.midX) <= 2 {
            col = 0
        } else {
            col = current.midX < visible.midX ? 0 : 1
        }
        let row: Int
        if abs(current.midY - visible.midY) <= 2 {
            row = 1 // cocoa Y-up: spanning height counts as top row
        } else {
            row = current.midY < visible.midY ? 0 : 1
        }
        let nextCol = min(max(col + dCol, 0), 1)
        let nextRow = min(max(row + dRow, 0), 1)
        switch (nextCol, nextRow) {
        case (0, 1): return .topLeft
        case (1, 1): return .topRight
        case (0, 0): return .bottomLeft
        default: return .bottomRight
        }
    }

    private func isCorner(_ action: WindowAction) -> Bool {
        switch action {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    /// Height of the main display — THE single pivot for converting between
    /// Cocoa global (origin = bottom-left of main display, Y-up) and Quartz
    /// global (origin = top-left of main display, Y-down). Every conversion in
    /// this file must go through these two functions; per-screen or
    /// max-of-screens pivots are wrong on any non-trivial arrangement.
    static func mainScreenHeight() -> CGFloat {
        if let s = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return s.frame.height
        }
        return CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
    }

    /// Cocoa rect → Quartz-global top-left origin (the AX write format).
    static func quartzOrigin(ofCocoa rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX, y: mainScreenHeight() - rect.maxY)
    }

    /// Quartz-global top-left origin + size → Cocoa rect (the AX read format).
    static func cocoaRect(quartzOrigin origin: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: origin.x,
            y: mainScreenHeight() - origin.y - size.height,
            width: size.width,
            height: size.height
        )
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
        return Self.cocoaRect(quartzOrigin: origin, size: size)
    }

    // MARK: - Min-size clamp handling

    /// Rect with the app's actual (possibly min-size-clamped) size, anchored
    /// to the tile's intended corner/edges so it never hangs off-screen.
    static func pinnedRect(target: CGRect, actualSize: CGSize, action: WindowAction) -> CGRect {
        var origin = target.origin
        switch action {
        case .rightHalf, .topRight, .bottomRight, .rightThird, .rightTwoThirds:
            origin.x = target.maxX - actualSize.width
        case .centerThird, .maximize, .almostMaximize, .center,
             // Full-width tiles: when an app can't fit the width, center it
             // so a clamped top/bottom half reads as centered, not parked.
             .topHalf, .bottomHalf:
            origin.x = target.midX - actualSize.width / 2
        default: break // left-anchored
        }
        switch action {
        case .topHalf, .topLeft, .topRight, .leftThird, .centerThird,
             .rightThird, .leftTwoThirds, .rightTwoThirds:
            origin.y = target.maxY - actualSize.height
        case .bottomHalf, .bottomLeft, .bottomRight:
            origin.y = target.minY
        // Full-height tiles: center vertically when height-clamped.
        case .leftHalf, .rightHalf:
            origin.y = target.midY - actualSize.height / 2
        default: break // vertical center already applied above for center/maximize
        }
        return CGRect(origin: origin, size: actualSize)
    }

    /// Some apps (Chrome, Electron, …) refuse AX resizes below their own
    /// minimum window size. The preceding position write still succeeds, so
    /// the window ends up anchored at the tile origin but OVERFLOWS the tile —
    /// for bottom/right anchors it hangs off-screen entirely. Re-pin it to the
    /// tile's intended corner/edges so a clamped window stays where it belongs.
    func rePinClamped(_ window: AXUIElement, target: CGRect, action: WindowAction) {
        guard let actual = cocoaFrame(of: window) else { return }
        let dw = actual.width - target.width
        let dh = actual.height - target.height
        guard dw > 0.5 || dh > 0.5 else { return }
        let fixed = Self.pinnedRect(target: target, actualSize: actual.size, action: action)
        Self.log("appMinSizeClamp \(action.rawValue): requested=\(target.size) got=\(actual.size) -> repin origin \(fixed.origin)")
        moveImmediate(window, to: fixed)
    }

    /// Reads the window frame repeatedly until it stops changing (apps apply
    /// min-size clamps asynchronously), bounded to ~0.3s.
    func settledFrame(of window: AXUIElement, tries: Int = 6, interval: Double = 0.05) -> CGRect? {
        var last = cocoaFrame(of: window)
        for _ in 0..<tries {
            Thread.sleep(forTimeInterval: interval)
            let now = cocoaFrame(of: window)
            if now == last { break }
            last = now
        }
        return last
    }

    /// Waits for the app's frame to stop changing (min-size clamps can land
    /// late), re-pins clamped results, and re-issues dropped grow writes.
    func settleAndRepin(_ window: AXUIElement, target: CGRect, action: WindowAction) {
        var last = cocoaFrame(of: window)
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.1)
            let now = cocoaFrame(of: window)
            if now == last { break }
            last = now
        }
        rePinClamped(window, target: target, action: action)
        // Grows occasionally get ignored (app busy right after launch or a
        // burst of writes): if the window is still smaller than the target,
        // re-issue the final frame.
        if let a = cocoaFrame(of: window),
           a.width < target.width - 0.5 || a.height < target.height - 0.5 {
            for _ in 0..<2 {
                moveImmediate(window, to: target)
                Thread.sleep(forTimeInterval: 0.15)
                if let p = cocoaFrame(of: window),
                   p.width >= target.width - 0.5 && p.height >= target.height - 0.5 {
                    break
                }
            }
        }
    }

    private func screen(for cocoaRect: CGRect) -> NSScreen? {
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    // MARK: - Debug round trip (--roundtrip CLI)

    /// Reads the raw Quartz AX frame of `window` (no conversion).
    func rawQuartzFrame(of window: AXUIElement) -> (origin: CGPoint, size: CGSize)? {
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
        return (origin, size)
    }

    /// Live validation of the Cocoa↔Quartz conversion against the frontmost
    /// window: read AX → convert to Cocoa → pick tile → convert back → write →
    /// re-read → report deltas. Prints a machine-checkable report so geometry
    /// can be verified without interactive hotkeys. Returns nil if no window.
    @discardableResult
    func debugRoundTrip(action: WindowAction, targetPID: Int32? = nil) -> String? {
        // Either the frontmost app's focused window (default) or a specific
        // app's focused window (matrix testing without focus games).
        let window: AXUIElement?
        if let targetPID {
            let appEl = AXUIElementCreateApplication(targetPID)
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) != .success || ref == nil {
                // Fall back to the app's first window (matrix harness).
                var windowsRef: AnyObject?
                guard
                    AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                    let windows = windowsRef as? [AXUIElement], !windows.isEmpty
                else { return nil }
                ref = windows[0]
            }
            window = (ref! as! AXUIElement)
        } else {
            window = frontWindow()
        }
        guard let window, let before = rawQuartzFrame(of: window) else { return nil }
        let appName = NSRunningApplication(processIdentifier: targetPID ?? -1)?.localizedName
            ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let beforeCocoa = Self.cocoaRect(quartzOrigin: before.origin, size: before.size)
        guard let screen = screen(for: beforeCocoa) else { return nil }
        // Same relative/cycling resolution the hotkey path uses.
        let resolved = resolvedAction(for: action, current: beforeCocoa, visible: screen.visibleFrame)
        let target = layoutRect(for: resolved, current: beforeCocoa, visible: screen.visibleFrame, screen: screen)
        let expectedQuartz = Self.quartzOrigin(ofCocoa: target)

        moveImmediate(window, to: target)
        settleAndRepin(window, target: target, action: resolved)
        let after = rawQuartzFrame(of: window) ?? before
        let afterCocoa = Self.cocoaRect(quartzOrigin: after.origin, size: after.size)
        let screens = NSScreen.screens
            .map { "\($0.localizedName) frame=\($0.frame) visible=\($0.visibleFrame)" }
            .joined(separator: " | ")

        return """
        roundtrip action=\(action.rawValue) resolved=\(resolved.rawValue) app=\(appName)
          mainScreenHeight=\(Self.mainScreenHeight())
          screens=\(screens)
          before  quartz=\(before.origin) size=\(before.size) -> cocoa=\(beforeCocoa)
          target  cocoa=\(target) -> expectedQuartz=\(expectedQuartz)
          after   quartz=\(after.origin) size=\(after.size) -> cocoa=\(afterCocoa)
          delta   quartz=(\(after.origin.x - expectedQuartz.x), \(after.origin.y - expectedQuartz.y)) size=(\(after.size.width - target.width), \(after.size.height - target.height))
        """
    }

    // MARK: - Layout

    /// Cocoa-space tile for `visible` (already the screen's visibleFrame) and `AppSettings.gap`.
    /// Used by `perform` and by `--dump-layout` so e2e asserts the same math.
    func layoutRect(for action: WindowAction, current: CGRect, visible: CGRect, screen: NSScreen? = nil) -> CGRect {
        let area = visible.insetBy(dx: AppSettings.gap, dy: AppSettings.gap)
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
        // Corner tiles: half width x half height (screen quadrants), so four
        // windows tile the screen 2x2 edge-to-edge. Arrows slide between them.
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
