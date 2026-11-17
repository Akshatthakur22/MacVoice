import Testing
@testable import VoiceTypingCore

@Suite("TranscriptReconcilerTests")
struct TranscriptReconcilerTests {
    @Test func phraseBufferAccumulatesPunctuationBoundariesAndFlushesTail() {
        var buffer = PhraseBuffer()
        #expect(buffer.append("Hello") == [])
        #expect(buffer.append(" there. How are you? Fine") == ["Hello there.", " How are you?"])
        #expect(buffer.flush() == " Fine")
        #expect(buffer.flush() == nil)
    }

    @Test func phraseBufferSupportsUnicodeAndIgnoresWhitespaceTail() {
        var buffer = PhraseBuffer()
        #expect(buffer.append("नमस्ते। 你好！") == ["नमस्ते।", " 你好！"])
        #expect(buffer.flush() == nil)
    }

    @Test func phraseBufferSplitsVeryLongUnpunctuatedInputAtWordBoundary() {
        var buffer = PhraseBuffer(maximumPhraseCharacters: 12)
        #expect(buffer.append("one two three four") == ["one two "])
        #expect(buffer.flush() == "three four")
    }

    @Test func ignoresHypothesesAndEmitsConfirmedPrefixOnce() throws {
        var reconciler = TranscriptReconciler()

        #expect(try reconciler.consume(.init(hypothesis: "hello", confirmedTranscript: "")) == "")
        #expect(try reconciler.consume(.init(hypothesis: "hello world", confirmedTranscript: "hello ")) == "hello")
        #expect(try reconciler.consume(.init(hypothesis: "hello world!", confirmedTranscript: "hello world", isFinal: true)) == " world")
    }

    @Test func keepsCombiningSequenceTogetherAtUpdateBoundary() throws {
        var reconciler = TranscriptReconciler()

        #expect(try reconciler.consume(.init(hypothesis: "e", confirmedTranscript: "e")) == "")
        #expect(try reconciler.consume(.init(hypothesis: "é ", confirmedTranscript: "e\u{301} ")) == "e\u{301}")
        #expect(try reconciler.consume(.init(hypothesis: "é नमस्ते", confirmedTranscript: "e\u{301} नमस्ते", isFinal: true)) == " नमस्ते")
    }

    @Test func rejectsRevisionToPreviouslyConfirmedBytes() throws {
        var reconciler = TranscriptReconciler()
        _ = try reconciler.consume(.init(hypothesis: "hello ", confirmedTranscript: "hello "))

        #expect(throws: TranscriptReconciliationError.confirmedTextWasRevised) {
            try reconciler.consume(.init(hypothesis: "hullo", confirmedTranscript: "hullo", isFinal: true))
        }
    }
}
