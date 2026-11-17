import Foundation

/// In-process, deterministic transcript cleanup for Polished mode. No model,
/// no network, no disk: a phrase is processed in well under a millisecond.
///
/// Design rule: only change text when the intent is unambiguous. Every edit
/// below has a guard for the ordinary-speech case it could otherwise damage
/// ("the next line of code", "user id", "example.com", "really really").
///
/// Pipeline (English-specific steps are skipped for other locales):
/// 1. Spoken commands: line breaks, paragraphs, bullets, and punctuation.
/// 2. Word cleanup: fillers, stutters, the pronoun "I", missing apostrophes.
/// 3. Punctuation spacing.
/// 4. Sentence capitalization that respects URLs, decimals, abbreviations,
///    and mixed-case words such as "iPhone".
public struct NativeSwiftTranscriptPolisher: TranscriptPolisher {
    public let locale: Locale

    public init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    private var isEnglish: Bool {
        (locale.language.languageCode?.identifier.lowercased() ?? "en") == "en"
    }

    public func polish(_ transcript: String) async throws -> String {
        polishText(transcript)
    }

    /// Synchronous form of `polish(_:)`.
    public func polishText(_ transcript: String) -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }

        var text = transcript
        if isEnglish { text = SpokenCommands.apply(to: text) }
        text = cleanLines(text)
        text = Self.normalizePunctuationSpacing(text)
        text = Self.capitalizeSentences(text)

        // Keep the phrase's original edge spacing so consecutive phrases join
        // naturally, but never leave spaces at the start of a new line.
        let body = text.trimmingCharacters(in: .whitespaces)
        let startsLine = body.first.map(Self.isLineBreak) ?? false
        let endsLine = body.last.map(Self.isLineBreak) ?? false
        let leading = startsLine ? "" : String(transcript.prefix(while: Self.isHorizontalSpace))
        let trailing = endsLine ? "" : String(transcript.reversed().prefix(while: Self.isHorizontalSpace))
        return leading + body + trailing
    }

    // MARK: - Word cleanup

    /// Hesitation sounds that never carry meaning in dictated text.
    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah"]

    /// Short function words that are essentially never doubled on purpose.
    /// Content words ("really really", "bye bye", "that that") are kept.
    private static let stutterWords: Set<String> = [
        "i", "a", "an", "the", "to", "and", "but", "so", "we", "it", "in", "on", "of",
        "for", "with", "my", "you", "he", "she", "they", "at", "this", "if", "or", "as"
    ]

    /// Apostrophe-less spellings that are not themselves English words.
    /// Deliberately excludes "id", "ill", "were", "well", "its", "lets", "hell", "shell".
    private static let contractions: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't",
        "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't", "werent": "weren't",
        "cant": "can't", "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't",
        "wont": "won't", "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't",
        "mustnt": "mustn't", "neednt": "needn't",
        "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's",
        "wheres": "where's", "whos": "who's",
        "im": "I'm", "ive": "I've",
        "youre": "you're", "youve": "you've", "youll": "you'll",
        "theyre": "they're", "theyve": "they've", "theyll": "they'll",
        "weve": "we've", "itll": "it'll"
    ]

    private static let pronounIForms: Set<String> = ["i'm", "i've", "i'll", "i'd", "i’m", "i’ve", "i’ll", "i’d"]

    private func cleanLines(_ text: String) -> String {
        var output = ""
        var line = ""
        for character in text {
            if Self.isLineBreak(character) {
                output += cleanLine(line)
                output.append(character)
                line = ""
            } else {
                line.append(character)
            }
        }
        output += cleanLine(line)
        return output
    }

    private func cleanLine(_ line: String) -> String {
        var cleaned: [String] = []
        var previousWord = ""
        var previousHadTrailingPunctuation = false

        for raw in line.split(whereSeparator: Self.isHorizontalSpace).map(String.init) {
            let stripped = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard !stripped.isEmpty else {
                cleaned.append(raw)
                previousWord = ""
                continue
            }
            let trailingPunctuation = String(raw.reversed().prefix(while: \.isPunctuation).reversed())

            if isEnglish && Self.fillers.contains(stripped) {
                // "I think, uh." must keep its sentence end.
                if let terminal = trailingPunctuation.last(where: { ".?!".contains($0) }),
                   var previous = cleaned.last {
                    while let last = previous.last, ",;:".contains(last) { previous.removeLast() }
                    if !(previous.last.map { ".?!".contains($0) } ?? false) { previous.append(terminal) }
                    cleaned[cleaned.count - 1] = previous
                }
                continue
            }

            if isEnglish, stripped == previousWord, !previousHadTrailingPunctuation,
               Self.stutterWords.contains(stripped) {
                continue
            }

            previousWord = stripped
            previousHadTrailingPunctuation = !trailingPunctuation.isEmpty
            cleaned.append(isEnglish ? normalizeEnglishWord(raw, stripped: stripped) : raw)
        }
        return cleaned.joined(separator: " ")
    }

    private func normalizeEnglishWord(_ raw: String, stripped: String) -> String {
        let leading = String(raw.prefix(while: \.isPunctuation))
        let trailing = String(raw.reversed().prefix(while: \.isPunctuation).reversed())
        guard leading.count + trailing.count < raw.count else { return raw }
        let core = String(raw.dropFirst(leading.count).dropLast(trailing.count))

        if stripped == "i" || Self.pronounIForms.contains(stripped) {
            return leading + "I" + core.dropFirst() + trailing
        }
        if let fixed = Self.contractions[stripped], core.lowercased() == stripped {
            let startsUpper = core.first?.isUppercase ?? false
            let replacement = startsUpper ? fixed.prefix(1).uppercased() + fixed.dropFirst() : fixed
            return leading + replacement + trailing
        }
        return raw
    }

    // MARK: - Punctuation and capitalization

    static func normalizePunctuationSpacing(_ text: String) -> String {
        var result = text
        // "word ," → "word," but leave ".NET" and " .5" alone.
        result = result.replacingOccurrences(of: "[ \\t]+([,.?!:;])(?=\\s|$)", with: "$1", options: .regularExpression)
        // Collapse doubled soft punctuation produced by spoken + automatic punctuation.
        result = result.replacingOccurrences(of: "([,;:])[,;:]+", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[,;:]+([.?!])(?=\\s|$)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\?{2,}", with: "?", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<=\\S)[ \\t]{2,}", with: " ", options: .regularExpression)
        return result
    }

    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.",
        "st.", "approx.", "dept.", "inc.", "ltd.", "co.", "no.", "fig.", "est.", "cf.", "al."
    ]

    static func capitalizeSentences(_ text: String) -> String {
        var characters = Array(text)
        var shouldCapitalize = true
        for index in characters.indices {
            let character = characters[index]
            if shouldCapitalize && character.isLetter {
                if !hasInnerUppercase(characters, from: index) {
                    let upper = String(character).uppercased()
                    if upper.count == 1 { characters[index] = Character(upper) }
                }
                shouldCapitalize = false
            } else if shouldCapitalize && character.isNumber {
                // "5 people came" — the sentence already started.
                shouldCapitalize = false
            } else if isLineBreak(character) {
                shouldCapitalize = true
            } else if ".!?".contains(character) {
                if isSentenceEnd(characters, at: index) { shouldCapitalize = true }
            } else if character == "-", index + 1 < characters.count, characters[index + 1] == " ",
                      isAtLineStart(characters, index) {
                shouldCapitalize = true // "- milk" bullet item
            }
        }
        return String(characters)
    }

    /// True for "done. Next", false for "example.com", "3.5", "e.g. this".
    private static func isSentenceEnd(_ characters: [Character], at index: Int) -> Bool {
        var next = index + 1
        while next < characters.count, "\"'”’)]".contains(characters[next]) { next += 1 }
        guard next >= characters.count || characters[next].isWhitespace else { return false }
        guard characters[index] == "." else { return true }
        var start = index
        while start > 0, characters[start - 1].isLetter || characters[start - 1] == "." { start -= 1 }
        let token = String(characters[start...index]).lowercased()
        return !abbreviations.contains(token)
    }

    /// Words like "iPhone", "macOS", "eBay" keep their casing.
    private static func hasInnerUppercase(_ characters: [Character], from index: Int) -> Bool {
        var next = index + 1
        while next < characters.count, characters[next].isLetter {
            if characters[next].isUppercase { return true }
            next += 1
        }
        return false
    }

    private static func isAtLineStart(_ characters: [Character], _ index: Int) -> Bool {
        var previous = index - 1
        while previous >= 0 {
            if isLineBreak(characters[previous]) { return true }
            if !isHorizontalSpace(characters[previous]) { return false }
            previous -= 1
        }
        return true
    }

    static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\u{2028}"
    }

    static func isHorizontalSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }
}

/// Spoken formatting commands. Each command is skipped when the surrounding
/// words show it is being talked about rather than issued:
/// "draw a new line", "the next line of code", "add a comma here",
/// "the first bullet point is", "a long period".
enum SpokenCommands {
    struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        let precedingBlockers: Set<String>
        let followingBlockers: Set<String>
    }

    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "each", "every", "another", "any",
        "some", "no", "my", "your", "our", "their", "its", "his", "her", "whose", "which", "what",
        "first", "second", "third", "last", "same", "one", "per"
    ]
    private static let prepositions: Set<String> = ["on", "in", "at", "from", "into", "onto"]
    private static let lineFollowers: Set<String> = [
        "of", "character", "characters", "feed", "feeds", "separated", "delimited", "endings", "ending"
    ]
    private static let periodAdjectives: Set<String> = [
        "long", "short", "time", "trial", "grace", "waiting", "cooling", "given", "whole", "entire",
        "next", "previous", "initial", "final", "reporting", "billing", "notice", "probation", "rest",
        "transition", "holding", "warranty", "study", "school", "class", "free", "busy", "quiet"
    ]

    /// `\s*` before each command eats the space so punctuation attaches to the
    /// previous word; trailing `[.,;:!?]?` absorbs punctuation the recognizer
    /// added after the spoken command ("comma," / "new line.").
    private static let rules: [Rule] = [
        rule(#"\s*\b(?:shift enter|shift return|soft return|soft break)\b[.,;:!?]?[ \t]*"#, "\u{2028}"),
        rule(#"\s*\b(?:new paragraph|next paragraph|paragraph break)\b[.,;:!?]?[ \t]*"#, "\n\n",
             following: lineFollowers),
        rule(#"\s*\b(?:(?:switch|go|move) to (?:the )?next line|new line|line break)\b[.,;:!?]?[ \t]*"#, "\n",
             following: lineFollowers),
        rule(#"\s*\bnext line\b[.,;:!?]?[ \t]*"#, "\n",
             preceding: determiners.union(prepositions), following: lineFollowers),
        rule(#"\s*\bbullet point\b[.,;:!?]?[ \t]*"#, "\n- ", following: ["of", "is", "was", "are", "list", "lists"]),
        rule(#"\s*\bquestion mark\b[.,;:!?]?"#, "?"),
        rule(#"\s*\bexclamation (?:mark|point)\b[.,;:!?]?"#, "!"),
        rule(#"\s*\bfull stop\b[.,;:!?]?"#, "."),
        rule(#"\s*\bsemicolon\b[.,;:!?]?"#, ";"),
        rule(#"\s*\bcomma\b[.,;:!?]?"#, ",",
             following: ["separated", "delimited", "operator", "splice", "key", "button"]),
        // "period" is a common noun, so only treat it as a command when it is
        // the last word of the phrase ("I'm done period.").
        rule(#"\s*\bperiod\b[.!?]?(?=\s*$)"#, ".",
             preceding: determiners.union(periodAdjectives))
    ]

    private static func rule(
        _ pattern: String,
        _ replacement: String,
        preceding: Set<String> = determiners,
        following: Set<String> = []
    ) -> Rule {
        // Patterns are compile-time constants; a failure here is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return Rule(regex: regex, replacement: replacement, precedingBlockers: preceding, followingBlockers: following)
    }

    static func apply(to text: String) -> String {
        rules.reduce(text) { apply($1, to: $0) }
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        let mutable = NSMutableString(string: text)
        let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: mutable.length))
        // Replace from the end so earlier ranges stay valid.
        for match in matches.reversed() {
            let before = word(in: mutable, endingBefore: match.range.location)
            let after = word(in: mutable, startingAt: NSMaxRange(match.range))
            if rule.precedingBlockers.contains(before) || rule.followingBlockers.contains(after) { continue }
            mutable.replaceCharacters(in: match.range, with: rule.replacement)
        }
        return mutable as String
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x27 || unit == 0x2019
    }

    private static func isSpaceUnit(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    /// The word immediately before `location`, or "" if punctuation intervenes.
    private static func word(in text: NSString, endingBefore location: Int) -> String {
        var index = location - 1
        while index >= 0, isSpaceUnit(text.character(at: index)) { index -= 1 }
        let end = index + 1
        while index >= 0, isWordUnit(text.character(at: index)) { index -= 1 }
        let start = index + 1
        return end > start ? text.substring(with: NSRange(location: start, length: end - start)).lowercased() : ""
    }

    /// The word starting at or after `location`, or "" if punctuation intervenes.
    private static func word(in text: NSString, startingAt location: Int) -> String {
        var index = location
        while index < text.length, isSpaceUnit(text.character(at: index)) { index += 1 }
        let start = index
        while index < text.length, isWordUnit(text.character(at: index)) { index += 1 }
        return index > start ? text.substring(with: NSRange(location: start, length: index - start)).lowercased() : ""
    }
}
