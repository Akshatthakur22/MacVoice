import Foundation
import Testing
@testable import VoiceTypingCore
import TypingCore

/// Dictation must never end on its own. These tests cover the transcript path
/// that used to fail a session at the first pause after a finalized segment.
@Suite("ReliabilityTests")
struct ReliabilityTests {

    // MARK: Reconciler

    @Test func updateAfterSegmentEndDoesNotRetractTypedText() throws {
        var reconciler = TranscriptReconciler()
        let first = SpeechRecognitionUpdate(hypothesis: "Hi there.", confirmedTranscript: "Hi there.", endsSegment: true)
        #expect(try reconciler.consume(first) == "Hi there.")
        // The next segment has started but nothing new is confirmed yet.
        let next = SpeechRecognitionUpdate(hypothesis: "Hi there. How", confirmedTranscript: "Hi there.")
        #expect(try reconciler.consume(next) == "")
        let more = SpeechRecognitionUpdate(hypothesis: "Hi there. How are", confirmedTranscript: "Hi there. How")
        #expect(try reconciler.consume(more) == " Ho")
        let end = SpeechRecognitionUpdate(hypothesis: "Hi there. How are you?", confirmedTranscript: "Hi there. How are you?", endsSegment: true)
        #expect(try reconciler.consume(end) == "w are you?")
    }

    @Test func resynchronizeContinuesAfterARevision() throws {
        var reconciler = TranscriptReconciler()
        _ = try reconciler.consume(.init(hypothesis: "hello world", confirmedTranscript: "hello world", endsSegment: true))
        let revised = SpeechRecognitionUpdate(hypothesis: "hullo", confirmedTranscript: "hullo", endsSegment: true)
        #expect(throws: TranscriptReconciliationError.confirmedTextWasRevised) { try reconciler.consume(revised) }
        reconciler.resynchronize(to: revised)
        // Nothing is typed twice, and later text continues normally.
        #expect(try reconciler.consume(.init(hypothesis: "hullo there.", confirmedTranscript: "hullo there.", endsSegment: true))
                == " there.")
    }

    /// Thousands of random recognizer streams (growing volatile results, word
    /// revisions, punctuation and casing changes in finals, pauses) in both
    /// modes: the pipeline never throws and everything confirmed gets typed.
    @Test(arguments: [false, true])
    func randomRecognizerStreamsNeverFail(streaming: Bool) throws {
        var random = SeededRandom(seed: streaming ? 7 : 11)
        let vocabulary = ["the", "build", "is", "green", "send", "me", "report", "Friday", "we", "should", "ship",
                          "it", "API", "version", "3.5", "naïve", "café", "नमस्ते", "okay", "I", "think", "so"]
        for _ in 0..<2_000 {
            var assembler = ProgressiveTranscriptAssembler(commitsVolatileWords: streaming)
            var reconciler = TranscriptReconciler()
            var typed = ""
            for _ in 0..<random.int(1...4) {
                var words = (0..<random.int(1...8)).map { _ in vocabulary[random.int(0..<vocabulary.count)] }
                // Volatile results grow word by word, sometimes revising the last word.
                for count in 1...words.count {
                    var partial = Array(words[..<count])
                    if random.int(0..<4) == 0 { partial[count - 1] = vocabulary[random.int(0..<vocabulary.count)] }
                    let trailingSpace = random.bool() ? " " : ""
                    typed += try reconciler.consume(assembler.receive(text: partial.joined(separator: " ") + trailingSpace, isFinal: false))
                }
                // The final result may change casing and add punctuation.
                if random.bool() { words[0] = words[0].capitalized }
                let final = words.joined(separator: random.int(0..<5) == 0 ? ", " : " ") + [".", "?", "!", ""][random.int(0..<4)]
                typed += try reconciler.consume(assembler.receive(text: final, isFinal: true))
            }
            typed += try reconciler.consume(assembler.finalUpdate)
            #expect(typed == assembler.confirmedText)
        }
    }

    // MARK: Session

    /// The bug users saw: Polished dictation stopped itself at the first pause.
    @Test(arguments: [PolishingMode.polished, .verbatim])
    func dictationKeepsListeningAcrossPauses(mode: PolishingMode) async throws {
        let recognizer = MockSpeechRecognizer()
        let output = RecordingTypingOutput()
        let session = VoiceTypingSession(
            audioCapture: SilentAudioCapture(), recognizer: recognizer, typingEngine: output,
            polisher: NativeSwiftTranscriptPolisher(locale: Locale(identifier: "en_US")), polishingMode: mode)
        try await session.start()

        var assembler = ProgressiveTranscriptAssembler(commitsVolatileWords: mode == .verbatim)
        let script: [(String, Bool)] = [
            ("hey team", false), ("hey team the build is ", false), ("Hey team, the build is green.", true),
            ("can", false), ("can you send", false), ("can you send me the report ", false),
            ("Can you send me the report?", true),
            ("thanks", false), ("Thanks.", true),
        ]
        for (text, isFinal) in script {
            recognizer.send(assembler.receive(text: text, isFinal: isFinal))
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await session.state == .listening, "Dictation must not end by itself")

        await session.stop()
        #expect(await session.state == .idle)
        let expected = mode == .polished
            ? "Hey team, the build is green. Can you send me the report? Thanks."
            : "hey team the build is green. can you send me the report? Thanks."
        #expect(output.text == expected)
    }

    @Test func audioCaptureErrorsAreDescribed() {
        #expect(AudioCaptureError.noInputDevice.localizedDescription == "No usable microphone input is available.")
    }
}

// MARK: - Test doubles

private final class SilentAudioCapture: AudioCapturing {
    var onFrame: ((PCMFrame) -> Void)?
    var onError: ((AudioCaptureError) -> Void)?
    func start() throws {}
    func stop() {}
}

private final class RecordingTypingOutput: TypingOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var typed = ""
    var text: String { lock.withLock { typed } }
    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {
        lock.withLock { typed += text }
    }
    func stop() {}
    func drain() async {}
}

/// Deterministic SplitMix64 so failures reproduce.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { int(range.lowerBound..<(range.upperBound + 1)) }
    mutating func bool() -> Bool { next() & 1 == 1 }
}
