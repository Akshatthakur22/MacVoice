import ApplicationServices

/// Reads minimal context from the focused text field through Accessibility.
/// Only the single character before the insertion point is requested; nothing
/// is stored. Apps that do not expose text ranges simply return nil.
public enum FocusedTextContext {
    private static let messagingTimeout: Float = 0.15

    /// The character immediately before the caret, `nil` when the caret is at
    /// the start of the field or the app does not report it.
    public static func characterBeforeInsertionPoint() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location > 0 else { return nil }

        var previous = CFRange(location: selection.location - 1, length: 1)
        guard let previousRange = AXValueCreate(.cfRange, &previous) else { return nil }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, previousRange, &stringValue
        ) == .success, let string = stringValue as? String else { return nil }
        return string.last
    }

    /// Whether text starting with `first` needs a separating space after `previous`.
    public static func needsLeadingSpace(after previous: Character?, before first: Character?) -> Bool {
        guard let previous, let first else { return false }
        guard first.isLetter || first.isNumber else { return false }
        if previous.isWhitespace { return false }
        return !"([{\"'“‘/-@#_".contains(previous)
    }
}
