import XCTest
@testable import VoiceTypingCore

final class TranscriptReconcilerTests: XCTestCase {
    func testIgnoresHypothesesAndEmitsConfirmedPrefixOnce() throws {
        var reconciler = TranscriptReconciler()

        XCTAssertEqual(try reconciler.consume(.init(hypothesis: "hello", confirmedTranscript: "")), "")
        XCTAssertEqual(try reconciler.consume(.init(hypothesis: "hello world", confirmedTranscript: "hello ")), "hello")
        XCTAssertEqual(try reconciler.consume(.init(hypothesis: "hello world!", confirmedTranscript: "hello world", isFinal: true)), " world")
    }

    func testKeepsCombiningSequenceTogetherAtUpdateBoundary() throws {
        var reconciler = TranscriptReconciler()

        XCTAssertEqual(try reconciler.consume(.init(hypothesis: "e", confirmedTranscript: "e")), "")
        XCTAssertEqual(try reconciler.consume(.init(hypothesis: "é ", confirmedTranscript: "e\u{301} ")), "e\u{301}")
        XCTAssertEqual(try reconciler.consume(.init(hypothesis: "é नमस्ते", confirmedTranscript: "e\u{301} नमस्ते", isFinal: true)), " नमस्ते")
    }

    func testRejectsRevisionToPreviouslyConfirmedBytes() throws {
        var reconciler = TranscriptReconciler()
        _ = try reconciler.consume(.init(hypothesis: "hello ", confirmedTranscript: "hello "))

        XCTAssertThrowsError(try reconciler.consume(.init(hypothesis: "hullo", confirmedTranscript: "hullo", isFinal: true)))
    }
}
