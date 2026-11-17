import CoreGraphics

/// A text-preserving event description. Printable text stays grouped by Swift
/// extended grapheme cluster; control actions are represented explicitly.
enum InputAction: Equatable {
    case unicode(String)
    case keyCode(CGKeyCode)
    case shiftEnter

    /// Characters this action inserts (what Backspace must remove).
    var insertedCharacterCount: Int {
        switch self {
        case .unicode(let text): text.count
        case .keyCode, .shiftEnter: 1
        }
    }
}

enum TextEncoder {
    /// Walk without trimming or Unicode normalization. `.newline` preserves CR
    /// and LF scalars individually, including a CRLF pair, so chunk boundaries do
    /// not change the emitted action sequence. Key policies map each scalar to a
    /// corresponding keyboard action.
    /// macOS accepts at most 20 UTF-16 units in one keyboard event's Unicode payload.
    static let maximumUnitsPerEvent = 20

    /// - Parameter maxUnitsPerEvent: Printable text is grouped into events of
    ///   up to this many UTF-16 units without splitting a grapheme. 1 sends one
    ///   character per event (maximum compatibility).
    static func forEachAction(
        in text: String,
        newlineBehavior: NewlineBehavior,
        maxUnitsPerEvent: Int = 1,
        _ body: (InputAction) throws -> Void
    ) rethrows {
        let limit = min(max(1, maxUnitsPerEvent), maximumUnitsPerEvent)
        var pending = ""
        var pendingUnits = 0
        func flush() throws {
            guard !pending.isEmpty else { return }
            try body(.unicode(pending))
            pending = ""
            pendingUnits = 0
        }
        for character in text {
            let scalars = character.unicodeScalars
            let isPrintable = !(character == "\r" || character == "\n" || character == "\u{2028}"
                || character == "\t" || (scalars.count == 2 && scalars.first == "\r" && scalars.last == "\n"))
            if isPrintable {
                let units = character.utf16.count
                if pendingUnits + units > limit { try flush() }
                pending.append(character)
                pendingUnits += units
                continue
            }
            try flush()
            if scalars.count == 2 && scalars.first == "\r" && scalars.last == "\n" {
                try emitLineBreak(newlineBehavior, raw: "\r", to: body)
                try emitLineBreak(newlineBehavior, raw: "\n", to: body)
            } else if character == "\r" || character == "\n" {
                try emitLineBreak(newlineBehavior, raw: String(character), to: body)
            } else if character == "\u{2028}" {
                try body(.shiftEnter)
            } else if character == "\t" {
                try body(.unicode("\t"))
            }
        }
        try flush()
    }

    private static func emitLineBreak(
        _ behavior: NewlineBehavior,
        raw: String,
        to body: (InputAction) throws -> Void
    ) rethrows {
        switch behavior {
        case .enter, .smartChatAware, .newline: try body(.keyCode(36)) // Physical Return Key
        case .shiftEnter: try body(.shiftEnter) // Shift + Return Key
        case .omit: break
        }
    }
}
