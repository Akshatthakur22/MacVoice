import Foundation

/// Where a phrase will be typed, decided once per dictation.
public struct PolishContext: Sendable, Equatable {
    /// False when the phrase continues a sentence already in the field, so its
    /// first word must not be capitalized.
    public var startsSentence: Bool
    /// Terminals run what is typed: no capitalization, no apostrophes, no line
    /// commands, and no trailing sentence period.
    public var isTerminal: Bool

    public init(startsSentence: Bool = true, isTerminal: Bool = false) {
        self.startsSentence = startsSentence
        self.isTerminal = isTerminal
    }
}

/// The cleaned phrase plus any edit it asks for on already-typed text.
public struct PolishedPhrase: Sendable, Equatable {
    public var text: String
    /// The phrase was "scratch that": remove the previously typed phrase.
    public var retractsPreviousPhrase: Bool

    public init(text: String, retractsPreviousPhrase: Bool = false) {
        self.text = text
        self.retractsPreviousPhrase = retractsPreviousPhrase
    }
}

/// A replaceable asynchronous transcript-cleanup backend.
public protocol TranscriptPolisher: Sendable {
    func polishPhrase(_ transcript: String, context: PolishContext) async throws -> PolishedPhrase
}

public extension TranscriptPolisher {
    func polish(_ transcript: String) async throws -> String {
        try await polishPhrase(transcript, context: PolishContext()).text
    }
}

public struct PassthroughTranscriptPolisher: TranscriptPolisher {
    public init() {}
    public func polishPhrase(_ transcript: String, context: PolishContext) async throws -> PolishedPhrase {
        PolishedPhrase(text: transcript)
    }
}

public enum PolishingMode: String, CaseIterable, Sendable {
    case verbatim
    case polished
}

/// Converts punctuation-delimited stable text into phrases. No silence timing
/// is currently provided by Apple SpeechAnalyzer, so stop always flushes the tail.
///
/// Latin sentence punctuation (. ! ?) only ends a phrase when whitespace follows
/// it, so "example.com" and "3.5" stay in one phrase. A trailing "." waits for
/// the next character; the reconciler already withholds the last character of
/// each update, so this adds no delay in practice.
public struct PhraseBuffer: Sendable {
    private var pending = ""
    private let maximumPhraseCharacters: Int
    public init(maximumPhraseCharacters: Int = 360) { self.maximumPhraseCharacters = maximumPhraseCharacters }

    public mutating func append(_ stableDelta: String) -> [String] {
        pending += stableDelta
        var phrases: [String] = []
        while let end = Self.firstBoundaryEnd(in: pending) {
            phrases.append(String(pending[..<end]))
            pending = String(pending[end...])
        }
        while pending.count >= maximumPhraseCharacters {
            let end = pending.index(pending.startIndex, offsetBy: maximumPhraseCharacters)
            if let space = pending[..<end].lastIndex(where: { $0.isWhitespace }) {
                let cut = pending.index(after: space)
                phrases.append(String(pending[..<cut]))
                pending = String(pending[cut...])
            } else { break }
        }
        return phrases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public mutating func flush() -> String? {
        defer { pending = "" }
        guard !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return pending
    }

    /// Index just past the first phrase boundary, if one is complete.
    private static func firstBoundaryEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if "。！？।\n\u{2028}".contains(character) {
                return next
            }
            if ".!?".contains(character) {
                // Include closing quotes/brackets that belong to the sentence.
                var end = next
                while end < text.endIndex, "\"'”’)]".contains(text[end]) { end = text.index(after: end) }
                if end < text.endIndex, text[end].isWhitespace { return end }
            }
            index = next
        }
        return nil
    }
}
