import Foundation
import VoiceTypingCore

@main
enum VoiceTypingCoreChecks {
    static func main() async throws {
        var reconciler = TranscriptReconciler()
        expect(try reconciler.consume(.init(hypothesis: "hello", confirmedTranscript: "")), "")
        expect(try reconciler.consume(.init(hypothesis: "hello world", confirmedTranscript: "hello ")), "hello")
        expect(try reconciler.consume(.init(hypothesis: "hello world!", confirmedTranscript: "hello world", isFinal: true)), " world")

        reconciler.reset()
        expect(try reconciler.consume(.init(hypothesis: "e", confirmedTranscript: "e")), "")
        expect(try reconciler.consume(.init(hypothesis: "é ", confirmedTranscript: "e\u{301} ")), "e\u{301}")
        expect(try reconciler.consume(.init(hypothesis: "é नमस्ते", confirmedTranscript: "e\u{301} नमस्ते", isFinal: true)), " नमस्ते")

        reconciler.reset()
        _ = try reconciler.consume(.init(hypothesis: "hello ", confirmedTranscript: "hello "))
        do {
            _ = try reconciler.consume(.init(hypothesis: "hullo", confirmedTranscript: "hullo", isFinal: true))
            preconditionFailure("Expected a confirmed-prefix revision to be rejected")
        } catch TranscriptReconciliationError.confirmedTextWasRevised {
            try checkPhraseBuffer()
            let nativePolisher = NativeSwiftTranscriptPolisher()
            let nativeResult = try await nativePolisher.polish("um i think we should ship it next week")
            expect(nativeResult, "I think we should ship it next week")

            let lineBreakResult = try await nativePolisher.polish("hello new line im doing great")
            expect(lineBreakResult, "Hello\nI'm doing great")

            let shiftEnterResult = try await nativePolisher.polish("hello shift enter world")
            expect(shiftEnterResult, "Hello\u{2028}World")

            let switchLineResult = try await nativePolisher.polish("switch to next line hello")
            expect(switchLineResult, "\nHello")

            let bulletResult = try await nativePolisher.polish("grocery items bullet point milk bullet point eggs")
            expect(bulletResult, "Grocery items\n- Milk\n- Eggs")

            let legitimateRepeatResult = try await nativePolisher.polish("he said that that was true and had had no doubt")
            expect(legitimateRepeatResult, "He said that that was true and had had no doubt")

            let nonEnglishPolisher = NativeSwiftTranscriptPolisher(locale: Locale(identifier: "fr-FR"))
            let frenchResult = try await nonEnglishPolisher.polish("bonjour a tous")
            expect(frenchResult, "Bonjour a tous")
            // Final punctuation attaches to an already-typed word without revising it.
            let r1 = ProgressiveTranscriptAssembler.reconcileFinalText(
                currentConfirmed: "hello world",
                segmentBase: "",
                finalText: "Hello world. How are you?"
            )
            expect(r1, "hello world. How are you?")

            // A trailing space cannot take punctuation; the result must still extend it.
            let r2 = ProgressiveTranscriptAssembler.reconcileFinalText(
                currentConfirmed: "hello world ",
                segmentBase: "",
                finalText: "Hello world. How are you?"
            )
            expect(r2, "hello world How are you?")

            // Recognizer inserted a word at the front of the final result.
            let r3 = ProgressiveTranscriptAssembler.reconcileFinalText(
                currentConfirmed: "the world, this is a test or speech dictation in ",
                segmentBase: "",
                finalText: "In the world, this is a test or speech dictation in McVoice."
            )
            expect(r3, "the world, this is a test or speech dictation in McVoice.")
            print("VoiceTypingCore checks passed")
        }
    }

    private static func checkPhraseBuffer() throws {
        var buffer = PhraseBuffer()
        expect(buffer.append("Hello"), [])
        expect(buffer.append(" there. How are you? Fine"), ["Hello there.", " How are you?"])
        expect(buffer.flush() ?? "", " Fine")

        buffer = PhraseBuffer()
        expect(buffer.append("नमस्ते। 你好！"), ["नमस्ते।", " 你好！"])
        expect(buffer.flush(), nil)
    }

    private static func expect(_ actual: String, _ expected: String) {
        precondition(actual == expected, "Expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T) {
        precondition(actual == expected, "Expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
    }
}
