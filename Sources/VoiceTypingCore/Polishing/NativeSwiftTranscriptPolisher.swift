import Foundation
import NaturalLanguage

/// In-process, deterministic transcript cleanup for Polished mode. No model,
/// no network, no disk: a phrase is processed in well under a millisecond.
///
/// Design rule: only change text when the intent is unambiguous. Every edit
/// below has a guard for the ordinary-speech case it could otherwise damage
/// ("the next line of code", "user id", "example.com", "really really").
///
/// Pipeline (English-specific steps are skipped for other locales):
/// 1. The user's replacements ("mac voice" → "MacVoice").
/// 2. "Scratch that": drop the words before it, or the previous phrase.
/// 3. Spoken commands: line breaks, paragraphs, bullets, and punctuation.
/// 4. Word cleanup: fillers, stutters, the pronoun "I", missing apostrophes.
/// 5. Punctuation spacing.
/// 6. Sentence capitalization that respects URLs, decimals, abbreviations,
///    mixed-case words such as "iPhone", and text already before the caret.
///
/// In a terminal only replacements, "scratch that", fillers, and stutters
/// apply: capitals, apostrophes, line commands, and a trailing period would
/// change the command being typed.
public struct NativeSwiftTranscriptPolisher: TranscriptPolisher {
    public let locale: Locale
    public let replacements: [TextReplacement]

    public init(locale: Locale = Locale.current, replacements: [TextReplacement] = []) {
        self.locale = locale
        // Longest phrases first so "mac voice app" wins over "mac voice".
        self.replacements = replacements.sorted { $0.spoken.count > $1.spoken.count }
    }

    private var isEnglish: Bool {
        (locale.language.languageCode?.identifier.lowercased() ?? "en") == "en"
    }

    public func polishPhrase(_ transcript: String, context: PolishContext) async throws -> PolishedPhrase {
        polishedPhrase(transcript, context: context)
    }

    /// Synchronous form returning only the text.
    public func polishText(_ transcript: String, context: PolishContext = PolishContext()) -> String {
        polishedPhrase(transcript, context: context).text
    }

    /// Synchronous form of `polishPhrase(_:context:)`.
    public func polishedPhrase(_ transcript: String, context: PolishContext = PolishContext()) -> PolishedPhrase {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PolishedPhrase(text: transcript)
        }

        var text = Self.applyReplacements(replacements, to: transcript)
        var retractsPrevious = false
        if isEnglish, let scratch = SpokenCommands.applyScratch(to: text) {
            retractsPrevious = scratch.retractsPrevious
            // Keep the phrase's own leading spacing, not the space after the command.
            text = String(text.prefix(while: Self.isHorizontalSpace))
                + scratch.remainder.drop(while: Self.isHorizontalSpace)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return PolishedPhrase(text: "", retractsPreviousPhrase: retractsPrevious)
            }
        }

        let edges = text // phrase spacing to restore after word cleanup
        if isEnglish {
            text = SpokenCommands.apply(to: text, includingLineCommands: !context.isTerminal)
        }
        text = cleanLines(text, normalizeWords: !context.isTerminal)
        text = Self.normalizePunctuationSpacing(text)

        var body = text.trimmingCharacters(in: .whitespaces)
        if context.isTerminal {
            // "git status." would not run; keep "?" and "!" and ellipses.
            body = body.replacingOccurrences(of: "(?<!\\.)\\.$", with: "", options: .regularExpression)
            // The recognizer capitalizes "Git status"; shell commands are lowercase.
            if isEnglish { body = Self.lowercasingCommonFirstWord(body) }
        } else {
            body = Self.capitalizeSentences(body, startsSentence: context.startsSentence)
            if !context.startsSentence && isEnglish { body = Self.lowercasingCommonFirstWord(body) }
        }
        guard !body.isEmpty else { return PolishedPhrase(text: "", retractsPreviousPhrase: retractsPrevious) }

        // Keep the phrase's original edge spacing so consecutive phrases join
        // naturally, but never leave spaces at the start of a new line.
        let startsLine = body.first.map(Self.isLineBreak) ?? false
        let endsLine = body.last.map(Self.isLineBreak) ?? false
        let leading = startsLine ? "" : String(edges.prefix(while: Self.isHorizontalSpace))
        let trailing = endsLine ? "" : String(edges.reversed().prefix(while: Self.isHorizontalSpace))
        return PolishedPhrase(text: leading + body + trailing, retractsPreviousPhrase: retractsPrevious)
    }

    // MARK: - Replacements

    static func applyReplacements(_ replacements: [TextReplacement], to text: String) -> String {
        var result = text
        for replacement in replacements {
            let words = replacement.spoken.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            // Whole words only; spoken words may be separated by spaces or hyphens.
            let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s-]+") + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.written)
            )
        }
        return result
    }

    // MARK: - Word cleanup

    /// Hesitation sounds that never carry meaning in dictated text.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah"]

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

    private func cleanLines(_ text: String, normalizeWords: Bool) -> String {
        var output = ""
        var line = ""
        for character in text {
            if Self.isLineBreak(character) {
                output += cleanLine(line, normalizeWords: normalizeWords)
                output.append(character)
                line = ""
            } else {
                line.append(character)
            }
        }
        output += cleanLine(line, normalizeWords: normalizeWords)
        return output
    }

    private func cleanLine(_ line: String, normalizeWords: Bool) -> String {
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
            cleaned.append(isEnglish && normalizeWords ? normalizeEnglishWord(raw, stripped: stripped) : raw)
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

    static func capitalizeSentences(_ text: String, startsSentence: Bool = true) -> String {
        var characters = Array(text)
        var shouldCapitalize = startsSentence
        for index in characters.indices {
            let character = characters[index]
            if shouldCapitalize && character.isLetter {
                if !preservesCase(characters, from: index) {
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

    /// Tokens that keep their exact casing at a sentence start: mixed-case
    /// words ("iPhone", "macOS"), emails, paths, URLs, and snake_case.
    private static func preservesCase(_ characters: [Character], from index: Int) -> Bool {
        var next = index + 1
        while next < characters.count, !characters[next].isWhitespace {
            let character = characters[next]
            if character.isUppercase || "@/_".contains(character) { return true }
            if character == ".", next + 1 < characters.count, characters[next + 1].isLetter { return true }
            next += 1
        }
        return false
    }

    private static let pronounI: Set<String> = ["I", "I'm", "I've", "I'll", "I'd", "I’m", "I’ve", "I’ll", "I’d"]

    /// When dictation continues a sentence already in the field, the
    /// recognizer still capitalizes its first word ("…we should That"). Undo
    /// that unless the word is "I", an acronym, or a name (via Apple's
    /// on-device NaturalLanguage tagger).
    static func lowercasingCommonFirstWord(_ text: String) -> String {
        guard let start = text.firstIndex(where: \.isLetter) else { return text }
        let end = text[start...].firstIndex(where: { !$0.isLetter && $0 != "'" && $0 != "’" }) ?? text.endIndex
        let word = String(text[start..<end])
        guard let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy({ !$0.isUppercase }),
              !pronounI.contains(word) else { return text }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: start, unit: .word, scheme: .nameType)
        if let tag, [.personalName, .placeName, .organizationName].contains(tag) { return text }

        return text.replacingCharacters(in: start...start, with: String(first).lowercased())
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
    private static let lineRules: [Rule] = [
        rule(#"\s*\b(?:shift enter|shift return|soft return|soft break)\b[.,;:!?]?[ \t]*"#, "\u{2028}"),
        rule(#"\s*\b(?:new paragraph|next paragraph|paragraph break)\b[.,;:!?]?[ \t]*"#, "\n\n",
             following: lineFollowers),
        rule(#"\s*\b(?:(?:switch|go|move) to (?:the )?next line|new line|line break)\b[.,;:!?]?[ \t]*"#, "\n",
             following: lineFollowers),
        rule(#"\s*\bnext line\b[.,;:!?]?[ \t]*"#, "\n",
             preceding: determiners.union(prepositions), following: lineFollowers),
        rule(#"\s*\bbullet point\b[.,;:!?]?[ \t]*"#, "\n- ", following: ["of", "is", "was", "are", "list", "lists"])
    ]

    private static let punctuationRules: [Rule] = [
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

    static func apply(to text: String, includingLineCommands: Bool = true) -> String {
        let rules = includingLineCommands ? lineRules + punctuationRules : punctuationRules
        return rules.reduce(text) { apply($1, to: $0) }
    }

    // MARK: "Scratch that"

    private static let scratchRegex = try! NSRegularExpression(
        pattern: #"\bscratch that\b[.,;:!?]?"#, options: [.caseInsensitive]
    )
    /// "scratch that itch", "scratch that off the list", "scratch that card".
    private static let scratchFollowers: Set<String> = [
        "itch", "off", "out", "card", "ticket", "surface", "part", "area", "spot", "one", "too", "again"
    ]

    /// Finds "scratch that". Words before it in the same phrase are dropped;
    /// if nothing but fillers precedes the first one, the previously typed
    /// phrase should be removed instead. Returns nil when there is no command.
    static func applyScratch(to text: String) -> (remainder: String, retractsPrevious: Bool)? {
        let mutable = text as NSString
        let commands = scratchRegex.matches(in: text, range: NSRange(location: 0, length: mutable.length))
            .filter { !scratchFollowers.contains(word(in: mutable, startingAt: NSMaxRange($0.range))) }
        guard let first = commands.first, let last = commands.last else { return nil }

        let before = mutable.substring(to: first.range.location).lowercased()
        let wordsBefore = before.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        let retractsPrevious = wordsBefore.allSatisfy { NativeSwiftTranscriptPolisher.fillers.contains(String($0)) }
        return (mutable.substring(from: NSMaxRange(last.range)), retractsPrevious)
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
