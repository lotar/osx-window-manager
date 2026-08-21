import AppKit
import Carbon

/// Registers global hotkeys with the Carbon Event Manager — the same
/// mechanism Rectangle and Magnet use — and dispatches callbacks on the
/// main thread.
final class HotKeyManager {
    static let shared = HotKeyManager()

    typealias Handler = (WindowAction) -> Void

    private var handlers: [UInt32: WindowAction] = [:]
    private var refs: [UInt32: EventHotKeyRef?] = [:]
    private var handler: Handler?
    private var eventHandler: EventHandlerRef?

    private let sigBase: FourCharCode = 0x474C_53_4D // 'GLSM'

    func install(handler: @escaping Handler) {
        self.handler = handler
        installEventTarget()
        refresh()
    }

    /// Re-registers every shortcut currently in the store.
    func refresh() {
        // Unregister all existing.
        for ref in refs.values {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        handlers.removeAll()

        var seq: UInt32 = 0
        for (action, shortcut) in ShortcutsStore.shared.shortcuts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // Skip zero-modifier shortcuts — they would hijack normal typing.
            guard !shortcut.modifiers.isEmpty else { continue }
            let id = EventHotKeyID(signature: sigBase, id: seq)
            var newRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                shortcut.carbonModifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &newRef
            )
            if status == noErr {
                handlers[seq] = action
                refs[seq] = newRef
            }
            seq += 1
        }
    }

    fileprivate func dispatch(_ event: EventRef?) {
        guard let event, let handler else { return }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, let action = handlers[hotKeyID.id] else { return }
        DispatchQueue.main.async { handler(action) }
    }
}

// C-function callback bridge for the Carbon event target.
private var gHotKeyManager = HotKeyManager.shared

@_cdecl("glassHotKeyEventHandler")
func glassHotKeyEventHandler(_ callBack: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    gHotKeyManager.dispatch(event)
    return noErr
}

extension HotKeyManager {
    /// Called once at launch to install the shared event handler.
    func installEventTarget() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Dispatcher target is what Carbon hotkeys actually deliver to.
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            glassHotKeyEventHandler,
            1,
            &spec,
            nil,
            &eventHandler
        )
        if status != noErr {
            _ = InstallEventHandler(
                GetApplicationEventTarget(),
                glassHotKeyEventHandler,
                1,
                &spec,
                nil,
                &eventHandler
            )
        }
    }
}