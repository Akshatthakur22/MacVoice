import AppKit
import ApplicationServices

/// What MacVoice knows about the place it is about to type into. Captured once
/// when a dictation starts; nothing is stored beyond that dictation.
public struct InsertionContext: Sendable, Equatable {
    public enum Preceding: Sendable, Equatable {
        /// The app does not expose its text through Accessibility.
        case unknown
        /// The caret is at the very start of the field.
        case startOfText
        /// Up to three characters immediately before the caret.
        case text(String)
    }

    public var preceding: Preceding
    public var bundleIdentifier: String?

    public init(preceding: Preceding = .unknown, bundleIdentifier: String? = nil) {
        self.preceding = preceding
        self.bundleIdentifier = bundleIdentifier
    }

    public static let unknown = InsertionContext()

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "dev.warp.warp",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "com.mitchellh.ghostty", "com.termius-dmg.mac", "com.panic.prompt3"
    ]

    /// Terminals execute what is typed, so prose formatting must not apply.
    public var isTerminal: Bool {
        guard let id = bundleIdentifier?.lowercased() else { return false }
        return Self.terminalBundleIdentifiers.contains(id)
    }

    /// True when the caret sits inside a sentence ("I was saying|"), so the
    /// dictated text should not start with a capital letter.
    public var continuesSentence: Bool {
        guard case .text(let text) = preceding,
              let lastVisible = text.lastIndex(where: { !$0.isWhitespace }) else { return false }
        if text[text.index(after: lastVisible)...].contains(where: \.isNewline) { return false }
        let character = text[lastVisible]
        return character.isLetter || character.isNumber || ",;:".contains(character)
    }
}

/// Reads minimal context from the focused text field through Accessibility.
/// Only the few characters before the insertion point are requested.
public enum FocusedTextContext {
    private static let messagingTimeout: Float = 0.15
    private static let charactersToRead = 3

    public static func current() -> InsertionContext {
        InsertionContext(
            preceding: precedingText(),
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    public static func precedingText() -> InsertionContext.Preceding {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return .unknown }
        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unknown }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return .unknown }
        guard selection.location > 0 else { return .startOfText }

        let length = min(charactersToRead, selection.location)
        var previous = CFRange(location: selection.location - length, length: length)
        guard let previousRange = AXValueCreate(.cfRange, &previous) else { return .unknown }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, previousRange, &stringValue
        ) == .success, let string = stringValue as? String, !string.isEmpty else { return .unknown }
        return .text(string)
    }

    /// Adjusts the first text typed at a known position: adds a separating
    /// space after a word or sentence end, and drops a leading space where one
    /// is not wanted (start of field, after a space or line break).
    public static func adjustLeadingSpacing(_ text: String, after preceding: InsertionContext.Preceding) -> String {
        switch preceding {
        case .unknown:
            return text
        case .startOfText:
            return String(text.drop(while: { $0 == " " || $0 == "\t" }))
        case .text(let before):
            guard let previous = before.last else { return text }
            if previous.isWhitespace {
                return String(text.drop(while: { $0 == " " || $0 == "\t" }))
            }
            return needsLeadingSpace(after: previous, before: text.first) ? " " + text : text
        }
    }

    /// Whether text starting with `first` needs a separating space after `previous`.
    public static func needsLeadingSpace(after previous: Character?, before first: Character?) -> Bool {
        guard let previous, let first else { return false }
        guard first.isLetter || first.isNumber else { return false }
        if previous.isWhitespace { return false }
        return !"([{\"'“‘/-@#_".contains(previous)
    }
}
