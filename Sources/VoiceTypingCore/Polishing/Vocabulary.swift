import Foundation

/// "When I say X, type Y." Matched case-insensitively on whole words.
public struct TextReplacement: Sendable, Equatable {
    public let spoken: String
    public let written: String

    public init(spoken: String, written: String) {
        self.spoken = spoken
        self.written = written
    }
}

/// The user's custom words and replacements, edited as plain text in Settings.
///
/// - Custom words bias Apple's recognizer toward those spellings (both modes).
/// - Replacements rewrite recognized text in Polished mode.
public struct Vocabulary: Sendable, Equatable {
    public static let maximumContextualStrings = 100
    private static let separators = ["=>", "→", "->"]

    public var words: [String]
    public var replacements: [TextReplacement]
    /// Replacement lines that could not be understood, for user feedback.
    public var invalidLines: [String]

    public init(words: [String] = [], replacements: [TextReplacement] = [], invalidLines: [String] = []) {
        self.words = words
        self.replacements = replacements
        self.invalidLines = invalidLines
    }

    /// Parses one word or phrase per line, and `spoken => written` per line.
    /// Blank lines and lines starting with `#` are ignored.
    public init(wordsText: String, replacementsText: String) {
        var seen = Set<String>()
        words = Self.meaningfulLines(wordsText).filter { seen.insert($0.lowercased()).inserted }

        var replacements: [TextReplacement] = []
        var invalid: [String] = []
        var seenSpoken = Set<String>()
        for line in Self.meaningfulLines(replacementsText) {
            guard let separator = Self.separators.first(where: line.contains),
                  let range = line.range(of: separator) else {
                invalid.append(line)
                continue
            }
            let spoken = line[..<range.lowerBound]
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let written = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
            guard spoken.contains(where: { $0.isLetter || $0.isNumber }), !written.isEmpty else {
                invalid.append(line)
                continue
            }
            if seenSpoken.insert(spoken.lowercased()).inserted {
                replacements.append(TextReplacement(spoken: spoken, written: written))
            }
        }
        self.replacements = replacements
        self.invalidLines = invalid
    }

    /// Phrases for Apple's recognizer: custom words plus short replacement
    /// targets (so "MacVoice" is also a likely spelling), de-duplicated.
    public var contextualStrings: [String] {
        var seen = Set<String>()
        let targets = replacements.map(\.written).filter {
            !$0.contains("\n") && $0.split(separator: " ").count <= 4 && $0.count <= 40
        }
        return Array((words + targets).filter { seen.insert($0.lowercased()).inserted }
            .prefix(Self.maximumContextualStrings))
    }

    private static func meaningfulLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
