import Foundation

/// Builds an append-only confirmed transcript from segment-based recognizer
/// results (SpeechTranscriber style): volatile results describe the current
/// segment and may change, and a final result closes the segment.
///
/// Completed words from volatile results are committed early so Verbatim mode
/// can type live. Committed text never ends in whitespace, so when the final
/// result adds punctuation to the last committed word ("world" → "world.") it
/// can still be appended. Every update's `confirmedTranscript` is guaranteed to
/// extend the previous one, which is the contract `TranscriptReconciler` enforces.
public struct ProgressiveTranscriptAssembler: Sendable {
    public private(set) var confirmedText = ""
    private var segmentBase = ""
    private var segmentCommitted = ""
    /// When false, only final results are committed. Polished mode uses this:
    /// it types whole sentences anyway, and waiting keeps the recognizer's
    /// punctuation exact instead of losing it on words already typed.
    public let commitsVolatileWords: Bool

    public init(commitsVolatileWords: Bool = true) {
        self.commitsVolatileWords = commitsVolatileWords
    }

    public mutating func reset() {
        confirmedText = ""
        segmentBase = ""
        segmentCommitted = ""
    }

    /// Consumes one recognizer result and returns the cumulative update.
    public mutating func receive(text: String, isFinal: Bool) -> SpeechRecognitionUpdate {
        if isFinal {
            let full = Self.reconcileFinalText(
                currentConfirmed: confirmedText,
                segmentBase: segmentBase,
                finalText: text
            )
            confirmedText = full
            segmentBase = full
            segmentCommitted = ""
            return SpeechRecognitionUpdate(hypothesis: full, confirmedTranscript: full, isFinal: false, endsSegment: true)
        }

        // A word is complete once whitespace follows it. Commit through the end
        // of the last complete word, excluding the whitespace itself.
        if commitsVolatileWords, let lastSpace = text.lastIndex(where: \.isWhitespace) {
            let stable = String(text[..<lastSpace]).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression
            )
            if !stable.allSatisfy(\.isWhitespace),
               stable.hasPrefix(segmentCommitted),
               stable.count > segmentCommitted.count {
                let candidate = Self.join(segmentBase, stable)
                if candidate.hasPrefix(confirmedText) {
                    segmentCommitted = stable
                    confirmedText = candidate
                }
            }
        }
        return SpeechRecognitionUpdate(
            hypothesis: Self.join(segmentBase, text),
            confirmedTranscript: confirmedText,
            isFinal: false
        )
    }

    /// The closing update for a stopped session; releases any withheld text.
    public var finalUpdate: SpeechRecognitionUpdate {
        SpeechRecognitionUpdate(hypothesis: confirmedText, confirmedTranscript: confirmedText, isFinal: true)
    }

    /// Joins a finished segment and the next segment's text with exactly one
    /// separating space when neither side already supplies whitespace.
    public static func join(_ base: String, _ text: String) -> String {
        guard let last = base.last, let first = text.first else { return base + text }
        if last.isWhitespace || first.isWhitespace || ",.;:!?)]}".contains(first) {
            return base + text
        }
        return base + " " + text
    }

    /// Reconciles a segment's final text with the words already committed from
    /// volatile results. The result always has `currentConfirmed` as a prefix.
    public static func reconcileFinalText(
        currentConfirmed: String,
        segmentBase: String,
        finalText: String
    ) -> String {
        let proposed = join(segmentBase, finalText)
        if proposed.hasPrefix(currentConfirmed) {
            return proposed
        }

        let committedPart = currentConfirmed.hasPrefix(segmentBase)
            ? currentConfirmed.dropFirst(segmentBase.count)
            : Substring(currentConfirmed)
        let committedWords = committedPart.split(whereSeparator: \.isWhitespace)
        let finalWords = finalText.split(whereSeparator: \.isWhitespace)
        let uncommitted = findUncommittedWords(committedWords: committedWords, finalWords: finalWords)

        // Carry over punctuation the final result attached to the last word we
        // already typed, but only when that word is still at the very end and
        // has no punctuation of its own.
        var punctuation = ""
        let lastMatchedIndex = finalWords.count - uncommitted.count - 1
        if !committedWords.isEmpty, lastMatchedIndex >= 0, lastMatchedIndex < finalWords.count,
           let lastCharacter = currentConfirmed.last,
           !lastCharacter.isWhitespace, !lastCharacter.isPunctuation {
            punctuation = extractTrailingPunctuation(from: finalWords[lastMatchedIndex])
        }

        var result = currentConfirmed + punctuation
        if !uncommitted.isEmpty {
            let needsSpace = !(result.last?.isWhitespace ?? true)
            result += (needsSpace ? " " : "") + uncommitted.joined(separator: " ")
        }
        return result
    }

    private static func extractTrailingPunctuation(from word: Substring) -> String {
        String(word.reversed().prefix(while: \.isPunctuation).reversed())
    }

    public static func findUncommittedWords(
        committedWords: [Substring],
        finalWords: [Substring]
    ) -> [Substring] {
        if committedWords.isEmpty { return finalWords }
        if finalWords.isEmpty { return [] }

        func normalize(_ word: Substring) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        let normCommitted = committedWords.map(normalize)
        let normFinal = finalWords.map(normalize)

        // 1. Final result starts with the committed words.
        var prefixMatch = 0
        while prefixMatch < normCommitted.count && prefixMatch < normFinal.count,
              normCommitted[prefixMatch] == normFinal[prefixMatch] {
            prefixMatch += 1
        }
        if prefixMatch == normCommitted.count {
            return Array(finalWords[prefixMatch...])
        }

        // 2. Align the tail of the committed words somewhere in the final words.
        let maxMatchLen = min(normCommitted.count, normFinal.count)
        for window in stride(from: maxMatchLen, through: 1, by: -1) {
            let committedTail = normCommitted[(normCommitted.count - window)...]
            for finalStart in stride(from: normFinal.count - window, through: 0, by: -1) {
                if committedTail.elementsEqual(normFinal[finalStart..<(finalStart + window)]) {
                    let uncommittedStart = finalStart + window
                    return uncommittedStart < finalWords.count ? Array(finalWords[uncommittedStart...]) : []
                }
            }
        }

        // 3. Partial prefix match.
        if prefixMatch > 0 {
            return Array(finalWords[prefixMatch...])
        }

        // 4. Last committed word appears somewhere in the final words.
        if let lastCommittedWord = normCommitted.last,
           let lastIndex = normFinal.lastIndex(of: lastCommittedWord),
           lastIndex + 1 < finalWords.count {
            return Array(finalWords[(lastIndex + 1)...])
        }

        return []
    }
}
