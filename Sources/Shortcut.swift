import AppKit
import Carbon

/// A global keyboard shortcut: a key code plus modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Raw value of NSEvent.ModifierFlags.
    var modifiersRaw: UInt

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRaw) }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.rawValue
    }

    /// Carbon modifier mask used by RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += Self.keyLabel(for: keyCode)
        return s
    }

    /// US-layout labels for Carbon/HI virtual keycodes.
    static func keyLabel(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "⏎"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "␣"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "Esc"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F12"
        case 111: return "F13"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "key \(keyCode)"
        }
    }
}

/// The window operations the app can perform.
enum WindowAction: String, CaseIterable, Identifiable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center, restore
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Quarter — Slide Left (←)"
        case .topRight: return "Quarter — Slide Right (→)"
        case .bottomLeft: return "Quarter — Slide Down (↓)"
        case .bottomRight: return "Quarter — Slide Up (↑)"
        case .leftThird: return "Left third"
        case .centerThird: return "Center third"
        case .rightThird: return "Right third"
        case .leftTwoThirds: return "Left two-thirds"
        case .rightTwoThirds: return "Right two-thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost maximize"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Next display"
        case .previousDisplay: return "Previous display"
        }
    }
}

/// UserDefaults-backed persistence for shortcut assignments.
final class ShortcutsStore {
    static let shared = ShortcutsStore()
    private let defaultsKey = "shortcuts.v1"
    private let userDefaults = UserDefaults.standard

    static let defaults: [WindowAction: Shortcut] = [
        .leftHalf: Shortcut(keyCode: 123, modifiers: [.command, .option]),
        .rightHalf: Shortcut(keyCode: 124, modifiers: [.command, .option]),
        .topHalf: Shortcut(keyCode: 126, modifiers: [.command, .option]),
        .bottomHalf: Shortcut(keyCode: 125, modifiers: [.command, .option]),
        .topLeft: Shortcut(keyCode: 123, modifiers: [.command, .option, .shift]),
        .topRight: Shortcut(keyCode: 124, modifiers: [.command, .option, .shift]),
        .bottomLeft: Shortcut(keyCode: 125, modifiers: [.command, .option, .shift]),
        .bottomRight: Shortcut(keyCode: 126, modifiers: [.command, .option, .shift]),
        .leftThird: Shortcut(keyCode: 18, modifiers: [.command, .option]),
        .centerThird: Shortcut(keyCode: 19, modifiers: [.command, .option]),
        .rightThird: Shortcut(keyCode: 20, modifiers: [.command, .option]),
        .leftTwoThirds: Shortcut(keyCode: 14, modifiers: [.command, .option]),
        .rightTwoThirds: Shortcut(keyCode: 17, modifiers: [.command, .option]),
        .maximize: Shortcut(keyCode: 36, modifiers: [.command, .option]),
        .almostMaximize: Shortcut(keyCode: 3, modifiers: [.command, .option]),
        .center: Shortcut(keyCode: 8, modifiers: [.command, .option]),
        .restore: Shortcut(keyCode: 6, modifiers: [.command, .option]),
        .nextDisplay: Shortcut(keyCode: 30, modifiers: [.command, .option]),
        .previousDisplay: Shortcut(keyCode: 33, modifiers: [.command, .option]),
    ]

    var shortcuts: [WindowAction: Shortcut] {
        get {
            guard
                let data = userDefaults.data(forKey: defaultsKey),
                let decoded = try? JSONDecoder().decode([WindowAction: Shortcut].self, from: data)
            else { return Self.defaults }
            return Self.defaults.merging(decoded) { _, saved in saved }
        }
    }

    func set(_ shortcut: Shortcut?, for action: WindowAction) {
        var current = shortcuts
        if let shortcut { current[action] = shortcut } else { current[action] = nil }
        save(current)
    }

    func resetToDefaults() { save(Self.defaults) }

    private func save(_ shortcuts: [WindowAction: Shortcut]) {
        if let data = try? JSONEncoder().encode(shortcuts) {
            userDefaults.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: Notification.Name("glass.shortcuts.didChange"), object: nil)
    }
}

enum GlassSettings {
    static let gapKey = "gap.v1"
    /// Tile gap in points, clamped 0...40. Default 0.
    static var gap: CGFloat {
        get {
            CGFloat(UserDefaults.standard.double(forKey: gapKey))
        }
        set {
            let clamped = min(max(newValue, 0), 40)
            UserDefaults.standard.set(Double(clamped), forKey: gapKey)
        }
    }
}
