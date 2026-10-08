import CoreGraphics

/// A text-preserving event description. Printable text stays grouped by Swift
/// extended grapheme cluster; control actions are represented explicitly.
enum InputAction: Equatable {
    case unicode(String)
    case keyCode(CGKeyCode)
    case shiftEnter
}

enum TextEncoder {
    /// Walk without trimming or Unicode normalization. `.newline` preserves CR
    /// and LF scalars individually, including a CRLF pair, so chunk boundaries do
    /// not change the emitted action sequence. Key policies map each scalar to a
    /// corresponding keyboard action.
    static func forEachAction(
        in text: String,
        newlineBehavior: NewlineBehavior,
        _ body: (InputAction) throws -> Void
    ) rethrows {
        for character in text {
            let scalars = character.unicodeScalars
            if scalars.count == 2 && scalars.first == "\r" && scalars.last == "\n" {
                try emitLineBreak(newlineBehavior, raw: "\r", to: body)
                try emitLineBreak(newlineBehavior, raw: "\n", to: body)
            } else if character == "\r" || character == "\n" {
                try emitLineBreak(newlineBehavior, raw: String(character), to: body)
            } else if character == "\t" {
                try body(.unicode("\t"))
            } else {
                try body(.unicode(String(character)))
            }
        }
    }

    private static func emitLineBreak(
        _ behavior: NewlineBehavior,
        raw: String,
        to body: (InputAction) throws -> Void
    ) rethrows {
        switch behavior {
        case .newline: try body(.unicode(raw))
        case .enter: try body(.keyCode(36)) // Return
        case .shiftEnter: try body(.shiftEnter)
        case .omit: break
        }
    }
}
