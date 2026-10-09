import Carbon
import Foundation

public enum GlobalShortcutError: Error, LocalizedError {
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "Could not register the global shortcut (Carbon status \(status))."
        }
    }
}

/// Registers a configurable system-wide Carbon hotkey while the host app's
/// event loop is running. The callback executes on that event loop.
public final class GlobalShortcut {
    public static let defaultKeyCode = UInt32(kVK_Space)
    public static let defaultModifiers = UInt32(controlKey | optionKey)

    public private(set) var keyCode: UInt32
    public private(set) var modifiers: UInt32
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callback: (() -> Void)?
    private var isSuspended = false

    public init(keyCode: UInt32 = GlobalShortcut.defaultKeyCode, modifiers: UInt32 = GlobalShortcut.defaultModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public func start(onPress: @escaping () -> Void) throws {
        guard hotKey == nil else { return }
        callback = onPress
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            voiceTypingHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            callback = nil
            throw GlobalShortcutError.registrationFailed(installStatus)
        }

        do {
            try registerHotKey()
        } catch {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            callback = nil
            throw error
        }
    }

    /// Temporarily disables the hotkey while a shortcut recorder is focused.
    public func suspend() {
        guard hotKey != nil else { return }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isSuspended = true
    }

    public func resume() throws {
        guard eventHandler != nil, isSuspended else { return }
        try registerHotKey()
        isSuspended = false
    }

    /// Changes the binding atomically. If Carbon rejects the new chord, the old
    /// chord is restored so the user never loses a working shortcut.
    public func update(keyCode newKeyCode: UInt32, modifiers newModifiers: UInt32) throws {
        let oldKeyCode = keyCode
        let oldModifiers = modifiers
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        keyCode = newKeyCode
        modifiers = newModifiers
        do {
            if eventHandler != nil { try registerHotKey() }
            isSuspended = false
        } catch {
            keyCode = oldKeyCode
            modifiers = oldModifiers
            if eventHandler != nil {
                do { try registerHotKey(); isSuspended = false }
                catch { isSuspended = true }
            }
            throw error
        }
    }

    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        callback = nil
        isSuspended = false
    }

    fileprivate func handlePress() {
        callback?()
    }

    private func registerHotKey() throws {
        let hotKeyID = EventHotKeyID(signature: OSType(0x56545950), id: 1)
        let status = withUnsafePointer(to: hotKeyID) { idPointer in
            RegisterEventHotKey(keyCode, modifiers, idPointer.pointee,
                                GetApplicationEventTarget(), 0, &hotKey)
        }
        guard status == noErr else { throw GlobalShortcutError.registrationFailed(status) }
    }

    deinit {
        stop()
    }
}

private func voiceTypingHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue().handlePress()
    return noErr
}
