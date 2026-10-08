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

/// Registers a system-wide Control+Option+Space shortcut while the host app's
/// event loop is running. The callback executes on that event loop.
public final class GlobalShortcut {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callback: (() -> Void)?

    public init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
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

        let hotKeyID = EventHotKeyID(signature: OSType(0x56545950), id: 1)
        let registerStatus = withUnsafePointer(to: hotKeyID) { idPointer in
            RegisterEventHotKey(
                keyCode,
                modifiers,
                idPointer.pointee,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
        }
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            callback = nil
            throw GlobalShortcutError.registrationFailed(registerStatus)
        }
    }

    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        callback = nil
    }

    fileprivate func handlePress() {
        callback?()
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
