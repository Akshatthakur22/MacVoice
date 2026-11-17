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
