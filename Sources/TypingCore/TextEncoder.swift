import CoreGraphics

/// A text-preserving event description. Printable text stays grouped by Swift
/// extended grapheme cluster; control actions are represented explicitly.
enum InputAction: Equatable {
    case unicode(String)
    case keyCode(CGKeyCode)
}

enum TextEncoder {
    /// Walk the string without trimming or Unicode normalization. CRLF is one
    /// logical line break; CR and LF independently follow the selected policy.
    static func forEachAction(
        in text: String,
        newlineBehavior: NewlineBehavior,
        _ body: (InputAction) throws -> Void
    ) rethrows {
        for character in text {
            let scalars = Array(character.unicodeScalars)
            if scalars.count == 2 && scalars[0] == "\r" && scalars[1] == "\n" {
                try emitLineBreak(newlineBehavior, to: body)
            } else if character == "\r" || character == "\n" {
                try emitLineBreak(newlineBehavior, to: body)
            } else if character == "\t" {
                try body(.keyCode(48)) // Tab
            } else {
                try body(.unicode(String(character)))
            }
        }
    }

    private static func emitLineBreak(
        _ behavior: NewlineBehavior,
        to body: (InputAction) throws -> Void
    ) rethrows {
        switch behavior {
        case .newline: try body(.unicode("\n"))
        case .enter: try body(.keyCode(36)) // Return
        case .omit: break
        }
    }
}
