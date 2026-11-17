import Foundation
import Testing
@testable import VoiceTypingCore
import TypingCore

@Suite("PolishingTests")
struct PolishingTests {
    private let polisher = NativeSwiftTranscriptPolisher(locale: Locale(identifier: "en_US"))

    // MARK: Assembler + reconciler (append-only contract end to end)

    private static let session: [(String, Bool)] = [
        ("hello", false), ("hello world how", false), ("hello world how are", false),
        ("Hello world. How are you?", true), ("I am", false), ("I am fine thanks", false),
        ("I am fine, thanks.", true)
    ]

    private func typedText(streaming: Bool) throws -> String {
        var assembler = ProgressiveTranscriptAssembler(commitsVolatileWords: streaming)
        var reconciler = TranscriptReconciler()
        var typed = ""
        for (text, isFinal) in Self.session {
            typed += try reconciler.consume(assembler.receive(text: text, isFinal: isFinal))
        }
        return typed + (try reconciler.consume(assembler.finalUpdate))
    }

    /// Live streaming: words already typed cannot be revised, so a period the
    /// recognizer adds after them is dropped, but the session never fails.
    @Test func liveStreamingStaysAppendOnlyThroughFinalResults() throws {
        #expect(try typedText(streaming: true) == "hello world how are you? I am fine, thanks.")
    }

    /// Final-only (Polished mode): punctuation and casing are exact.
    @Test func finalOnlyKeepsRecognizerPunctuation() throws {
        #expect(try typedText(streaming: false) == "Hello world. How are you? I am fine, thanks.")
    }

    @Test func punctuationAttachesWhenOnlyLastWordWasStreamed() throws {
        var assembler = ProgressiveTranscriptAssembler()
        var reconciler = TranscriptReconciler()
        var typed = try reconciler.consume(assembler.receive(text: "hello world how", isFinal: false))
        typed += try reconciler.consume(assembler.receive(text: "Hello world.", isFinal: true))
        typed += try reconciler.consume(assembler.finalUpdate)
        #expect(typed == "hello world.")
    }

    @Test func reconcileFinalTextAlwaysExtendsConfirmedText() {
        let cases: [(String, String)] = [
            ("hello world", "Hello world. How are you?"),
            ("hello world ", "Hello world. How are you?"),
            ("the world, this is in ", "In the world, this is in McVoice."),
            ("completely different", "Nothing matches here."),
            ("hello world,", "Hello world. Next")
        ]
        for (confirmed, final) in cases {
            let result = ProgressiveTranscriptAssembler.reconcileFinalText(
                currentConfirmed: confirmed, segmentBase: "", finalText: final)
            #expect(result.hasPrefix(confirmed), "\(result) must extend \(confirmed)")
        }
    }

    @Test func segmentsAreJoinedWithOneSpace() {
        #expect(ProgressiveTranscriptAssembler.join("Done.", "Next") == "Done. Next")
        #expect(ProgressiveTranscriptAssembler.join("Done.", " Next") == "Done. Next")
        #expect(ProgressiveTranscriptAssembler.join("Done", ", next") == "Done, next")
        #expect(ProgressiveTranscriptAssembler.join("", "Next") == "Next")
    }

    // MARK: Polisher — intended edits

    @Test func removesFillersAndKeepsSentenceEnd() {
        #expect(polisher.polishText("um i think we should ship it next week") == "I think we should ship it next week")
        #expect(polisher.polishText("So, um, we ship.") == "So, we ship.")
        #expect(polisher.polishText("I think, uh.") == "I think.")
    }

    @Test func spokenCommands() {
        #expect(polisher.polishText("hello new line im doing great") == "Hello\nI'm doing great")
        #expect(polisher.polishText("hello shift enter world") == "Hello\u{2028}World")
        #expect(polisher.polishText("grocery items bullet point milk bullet point eggs") == "Grocery items\n- Milk\n- Eggs")
        #expect(polisher.polishText("dear team comma thanks") == "Dear team, thanks")
        #expect(polisher.polishText("how are you question mark") == "How are you?")
        #expect(polisher.polishText("I'm done period.") == "I'm done.")
        #expect(polisher.polishText("That was it new paragraph Next topic.") == "That was it\n\nNext topic.")
    }

    @Test func fixesPronounAndContractions() {
        #expect(polisher.polishText("i dont know if im right") == "I don't know if I'm right")
        #expect(polisher.polishText("Dont stop.") == "Don't stop.")
        #expect(polisher.polishText("the the plan is ready") == "The plan is ready")
    }

    // MARK: Polisher — ordinary speech must be left alone

    @Test func leavesLookalikePhrasesAlone() {
        let unchanged = [
            "Pass the user id to the function.",
            "The patient is ill.",
            "On the next line of code we return early.",
            "Draw a new line under the title.",
            "The first bullet point is pricing.",
            "Add a comma here.",
            "It was a long period.",
            "She was really really happy.",
            "He said that that was true.",
            "Visit example.com for version 3.5 docs.",
            "Use e.g. this one.",
            "My iPhone works."
        ]
        for text in unchanged {
            #expect(polisher.polishText(text) == text)
        }
    }

    @Test func preservesEdgeSpacingButNotAfterLineBreak() {
        #expect(polisher.polishText(" how are you?") == " How are you?")
        #expect(polisher.polishText(" new line hello") == "\nHello")
    }

    @Test func nonEnglishOnlyGetsCapitalization() {
        let french = NativeSwiftTranscriptPolisher(locale: Locale(identifier: "fr-FR"))
        #expect(french.polishText("bonjour a tous") == "Bonjour a tous")
    }

    // MARK: Phrase boundaries

    @Test func phraseBufferIgnoresDotsInsideTokens() {
        var buffer = PhraseBuffer()
        #expect(buffer.append("visit example.com for version 3.5 now. Then") == ["visit example.com for version 3.5 now."])
        #expect(buffer.flush() == " Then")
        #expect(buffer.append("He said \"stop.\" Then") == ["He said \"stop.\""])
    }

    // MARK: Smart leading space

    @Test func leadingSpaceRule() {
        #expect(FocusedTextContext.needsLeadingSpace(after: ".", before: "H"))
        #expect(FocusedTextContext.needsLeadingSpace(after: "d", before: "n"))
        #expect(!FocusedTextContext.needsLeadingSpace(after: " ", before: "H"))
        #expect(!FocusedTextContext.needsLeadingSpace(after: "(", before: "H"))
        #expect(!FocusedTextContext.needsLeadingSpace(after: nil, before: "H"))
        #expect(!FocusedTextContext.needsLeadingSpace(after: "d", before: ","))
    }
}

@Suite("PolishingFeatureTests")
struct PolishingFeatureTests {
    private let en = Locale(identifier: "en_US")

    // MARK: Vocabulary

    @Test func vocabularyParsing() {
        let vocabulary = Vocabulary(
            wordsText: "# comment\nAPI\n  Kubernetes  \napi\n\n",
            replacementsText: "mac voice => MacVoice\nsig -> Best,\\nAkshat\nno separator here\n => empty\nmac voice => Duplicate"
        )
        #expect(vocabulary.words == ["API", "Kubernetes"])
        #expect(vocabulary.replacements == [
            TextReplacement(spoken: "mac voice", written: "MacVoice"),
            TextReplacement(spoken: "sig", written: "Best,\nAkshat")
        ])
        #expect(vocabulary.invalidLines == ["no separator here", "=> empty"])
        #expect(vocabulary.contextualStrings == ["API", "Kubernetes", "MacVoice"])
    }

    @Test func replacementsMatchWholeWordsAnyCase() {
        let polisher = NativeSwiftTranscriptPolisher(locale: en, replacements: [
            TextReplacement(spoken: "mac voice", written: "MacVoice"),
            TextReplacement(spoken: "my email", written: "a.b@example.com")
        ])
        #expect(polisher.polishText("I use Mac voice daily.") == "I use MacVoice daily.")
        #expect(polisher.polishText("I use mac-voice daily.") == "I use MacVoice daily.")
        #expect(polisher.polishText("Emacs voice notes.") == "Emacs voice notes.")
        #expect(polisher.polishText("my email.") == "a.b@example.com.")
    }

    // MARK: Scratch that

    @Test func scratchThat() {
        let polisher = NativeSwiftTranscriptPolisher(locale: en)
        #expect(polisher.polishedPhrase("I want pizza scratch that I want pasta.")
                == PolishedPhrase(text: "I want pasta."))
        #expect(polisher.polishedPhrase("Scratch that.") == PolishedPhrase(text: "", retractsPreviousPhrase: true))
        #expect(polisher.polishedPhrase(" Um, scratch that. Hello there.")
                == PolishedPhrase(text: " Hello there.", retractsPreviousPhrase: true))
        #expect(polisher.polishedPhrase("That will scratch that itch.") == PolishedPhrase(text: "That will scratch that itch."))
    }

    @Test func scratchThatRetractsPreviousTypedPhrase() async {
        let output = RecordingTypingOutput()
        let coordinator = PolishingCoordinator(
            engine: output, polisher: NativeSwiftTranscriptPolisher(locale: en), mode: .polished)
        await coordinator.begin()
        await coordinator.consume("Hello there. Scratch that. Goodbye")
        await coordinator.finish()
        #expect(output.events == [.append("Hello there."), .retract, .append(" Goodbye")])
    }

    // MARK: Cursor-aware capitalization

    @Test func continuingASentenceDoesNotCapitalize() {
        let polisher = NativeSwiftTranscriptPolisher(locale: en)
        let middle = PolishContext(startsSentence: false)
        #expect(polisher.polishText("That we should ship.", context: middle) == "that we should ship.")
        #expect(polisher.polishText("I think so.", context: middle) == "I think so.")
        #expect(polisher.polishText("NASA called.", context: middle) == "NASA called.")
        #expect(polisher.polishText("John Smith agreed.", context: middle) == "John Smith agreed.")
    }

    @Test func insertionContextDetectsSentencePosition() {
        #expect(InsertionContext(preceding: .text("was ")).continuesSentence)
        #expect(InsertionContext(preceding: .text("re,")).continuesSentence)
        #expect(!InsertionContext(preceding: .text("ne. ")).continuesSentence)
        #expect(!InsertionContext(preceding: .text("ne\n")).continuesSentence)
        #expect(!InsertionContext(preceding: .startOfText).continuesSentence)
        #expect(!InsertionContext(preceding: .unknown).continuesSentence)
    }

    @Test func leadingSpacingAdjustment() {
        #expect(FocusedTextContext.adjustLeadingSpacing("Next", after: .text("ne.")) == " Next")
        #expect(FocusedTextContext.adjustLeadingSpacing(" Next", after: .text("ne ")) == "Next")
        #expect(FocusedTextContext.adjustLeadingSpacing(" Next", after: .startOfText) == "Next")
        #expect(FocusedTextContext.adjustLeadingSpacing(" Next", after: .unknown) == " Next")
        #expect(FocusedTextContext.adjustLeadingSpacing(", then", after: .text("one")) == ", then")
    }

    // MARK: Terminal

    @Test func terminalKeepsCommandsRunnable() {
        let polisher = NativeSwiftTranscriptPolisher(locale: en)
        let terminal = PolishContext(isTerminal: true)
        #expect(polisher.polishText("Git status.", context: terminal) == "git status")
        #expect(polisher.polishText("um ls -i dont", context: terminal) == "ls -i dont")
        #expect(polisher.polishText("echo hi new line", context: terminal) == "echo hi new line")
        #expect(InsertionContext(bundleIdentifier: "com.apple.Terminal").isTerminal)
        #expect(!InsertionContext(bundleIdentifier: "com.apple.TextEdit").isTerminal)
    }
}

private final class RecordingTypingOutput: TypingOutput, @unchecked Sendable {
    enum Event: Equatable { case append(String), retract }
    private let lock = NSLock()
    private var recorded: [Event] = []
    var events: [Event] { lock.withLock { recorded } }

    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {
        lock.withLock { recorded.append(.append(text)) }
    }
    func retractLastAppend() { lock.withLock { recorded.append(.retract) } }
    func stop() {}
    func drain() async {}
}
