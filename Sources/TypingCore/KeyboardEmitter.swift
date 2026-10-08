import CoreGraphics

/// Emits a single Unicode grapheme as a Quartz key-down/key-up pair.
/// CGEvent's Unicode payload is layout-independent, but some apps ignore it.
struct KeyboardEmitter {
    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    func emit(_ action: InputAction) throws {
        switch action {
        case .unicode(let string): try emitUnicode(string)
        case .keyCode(let keyCode): try emitKeyCode(keyCode)
        case .shiftEnter: try emitShiftEnter()
        }
    }

    private func emitUnicode(_ string: String) throws {
        let units = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw TypingError.eventCreationFailed(eventPairsPosted: 0)
        }

        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func emitKeyCode(_ keyCode: CGKeyCode) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw TypingError.eventCreationFailed(eventPairsPosted: 0)
        }
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func emitShiftEnter() throws {
        let returnKey: CGKeyCode = 36
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw TypingError.eventCreationFailed(eventPairsPosted: 0)
        }
        down.flags.insert(.maskShift)
        up.flags.insert(.maskShift)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
