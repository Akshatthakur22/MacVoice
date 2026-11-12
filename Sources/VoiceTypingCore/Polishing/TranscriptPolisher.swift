import Foundation

/// A replaceable asynchronous transcript-cleanup backend.
public protocol TranscriptPolisher: Sendable {
    func polish(_ transcript: String) async throws -> String
}

public struct PassthroughTranscriptPolisher: TranscriptPolisher {
    public init() {}
    public func polish(_ transcript: String) async throws -> String { transcript }
}

/// Instant, zero-dependency in-process transcript normalizer.
/// Cleans filler words, removes stutters, capitalizes sentences, fixes contractions,
/// and handles natural line breaks in < 1 ms with 0 MB additional RAM.
public struct NativeSwiftTranscriptPolisher: TranscriptPolisher {
    public let locale: Locale
    public init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    private var isEnglish: Bool {
        let lang = locale.language.languageCode?.identifier.lowercased() ?? "en"
        return lang == "en"
    }

    private static let fillers: Set<String> = ["um", "uh", "erm", "ah"]
    private static let legitimateRepeats: Set<String> = [
        "that", "had", "is", "do", "no", "very", "bye", "many",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "zero"
    ]
    private static let contractions: [String: String] = [
        "dont": "don't", "cant": "can't", "wont": "won't",
        "didnt": "didn't", "isnt": "isn't", "arent": "aren't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't",
        "thats": "that's", "whats": "what's", "theres": "there's",
        "im": "I'm", "ive": "I've", "ill": "I'll", "id": "I'd"
    ]

    public func polish(_ transcript: String) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }

        var text = transcript

        // 1. Explicit voice navigation commands (for English dictation)
        if isEnglish {
            text = text.replacingOccurrences(of: "(?i)\\s*\\b(?:shift enter|shift return|soft return|soft break)\\b\\s*", with: "\u{2028}", options: .regularExpression)
            text = text.replacingOccurrences(of: "(?i)\\s*\\b(?:new paragraph|next paragraph|paragraph break)\\b\\s*", with: "\n\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "(?i)\\s*\\b(?:switch to next line|go to next line|move to next line|move to the next line|new line|next line|line break)\\b\\s*", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "(?i)\\bbullet point\\s+", with: "\n- ", options: .regularExpression)
        }

        // 2. Clean fillers, repeated stutters, contractions, and solo pronoun 'I'
        let lines = text.components(separatedBy: "\n")
        var cleanedLines: [String] = []

        for line in lines {
            let words = line.components(separatedBy: .whitespaces)
            var cleanedWords: [String] = []
            var lastWordLower = ""

            for rawWord in words {
                let stripped = rawWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if stripped.isEmpty {
                    if !rawWord.isEmpty { cleanedWords.append(rawWord) }
                    continue
                }
                if isEnglish && Self.fillers.contains(stripped) {
                    continue
                }
                if stripped == lastWordLower && stripped.count > 1 && !Self.legitimateRepeats.contains(stripped) {
                    continue
                }
                lastWordLower = stripped

                var word = rawWord
                if isEnglish {
                    if stripped == "i" {
                        word = rawWord.replacingOccurrences(of: "i", with: "I")
                    } else if let fixed = Self.contractions[stripped] {
                        let leadingPunct = rawWord.prefix(while: { $0.isPunctuation })
                        let trailingPunct = rawWord.reversed().prefix(while: { $0.isPunctuation }).reversed()
                        word = String(leadingPunct) + fixed + String(trailingPunct)
                    }
                }
                cleanedWords.append(word)
            }
            cleanedLines.append(cleanedWords.joined(separator: " "))
        }

        var result = cleanedLines.joined(separator: "\n")

        // 3. Clean punctuation spacing
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " :", with: ":")
        result = result.replacingOccurrences(of: " ;", with: ";")

        // 4. Sentence and list item capitalization
        result = capitalizeSentences(result)

        let leadingSpaces = transcript.prefix(while: \.isWhitespace)
        let trailingSpaces = transcript.reversed().prefix(while: \.isWhitespace).reversed()
        return String(leadingSpaces) + result.trimmingCharacters(in: .whitespaces) + String(trailingSpaces)
    }

    private func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var shouldCapitalize = true
        for i in 0..<chars.count {
            let c = chars[i]
            if shouldCapitalize && c.isLetter {
                chars[i] = Character(c.uppercased())
                shouldCapitalize = false
            } else if ".!?\n\u{2028}".contains(c) {
                shouldCapitalize = true
            } else if c == "-" {
                if i + 1 < chars.count && chars[i + 1] == " " {
                    shouldCapitalize = true
                }
            }
        }
        return String(chars)
    }
}

public enum PolishingMode: String, CaseIterable, Sendable {
    case verbatim
    case polished
}

/// Conservative post-generation checks; this rejects clear responses/rewrites,
/// but cannot prove semantic equivalence for an arbitrary language model.
public enum PolisherOutputValidator {
    private static let negations: Set<String> = ["no", "not", "never", "without", "cannot", "can't", "dont", "don't", "didn't", "isn't", "won't", "neither", "nor"]
    private static let removableFillers: Set<String> = ["um", "uh", "erm"]

    public static func validate(_ result: String, original: String) throws -> String {
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("```") else { throw PolisherError.invalidResponse }
        let inputTokens = tokens(original)
        let outputTokens = tokens(clean)
        guard !inputTokens.isEmpty, !outputTokens.isEmpty,
              outputTokens.count <= inputTokens.count,
              outputTokens.count >= max(1, inputTokens.count - inputTokens.filter(removableFillers.contains).count) else {
            throw PolisherError.invalidResponse
        }
        let distance = editDistance(inputTokens, outputTokens)
        let similarity = 1 - Double(distance) / Double(max(inputTokens.count, outputTokens.count))
        guard similarity >= 0.58 else { throw PolisherError.invalidResponse }
        // Accept case/punctuation edits and dropping known fillers only. Other
        // token edits can change intent, numbers, technical terms, or quotes.
        let sourceContent = inputTokens.filter { !removableFillers.contains($0) }
        let outputContent = outputTokens.filter { !removableFillers.contains($0) }
        guard sourceContent == outputContent else { throw PolisherError.invalidResponse }
        let requiredNumbers = inputTokens.filter { $0.contains(where: \.isNumber) }
        guard requiredNumbers.allSatisfy(outputTokens.contains) else { throw PolisherError.invalidResponse }
        let requiredNegations = inputTokens.filter { negations.contains($0.lowercased()) }
        guard requiredNegations.allSatisfy(outputTokens.contains) else { throw PolisherError.invalidResponse }
        let leadingEnd = original.firstIndex(where: { !$0.isWhitespace }) ?? original.endIndex
        let trailingStart = original.lastIndex(where: { !$0.isWhitespace }).map { original.index(after: $0) } ?? original.endIndex
        return String(original[..<leadingEnd]) + clean + String(original[trailingStart...])
    }

    private static func tokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                     previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

public enum PolisherError: Error, LocalizedError {
    case notInstalled, workerUnavailable, invalidResponse, timedOut
    case workerFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Local polishing model is not installed. Use Install Local Polishing Model first."
        case .workerUnavailable: "The local polishing worker stopped unexpectedly."
        case .invalidResponse: "The local polisher returned an empty or invalid response."
        case .timedOut: "Local transcript polishing timed out."
        case .workerFailed(let message): "Local transcript polishing failed: \(message)"
        }
    }
}

/// Converts punctuation-delimited stable text into phrases. No silence timing
/// is currently provided by Apple SpeechAnalyzer, so stop always flushes the tail.
public struct PhraseBuffer: Sendable {
    private var pending = ""
    private let maximumPhraseCharacters: Int
    public init(maximumPhraseCharacters: Int = 360) { self.maximumPhraseCharacters = maximumPhraseCharacters }

    public mutating func append(_ stableDelta: String) -> [String] {
        pending += stableDelta
        var phrases: [String] = []
        while let boundary = pending.firstIndex(where: { ".!?。！？।\n\u{2028}".contains($0) }) {
            let end = pending.index(after: boundary)
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
}
