import VoiceTypingCore

@main
enum VoiceTypingCoreChecks {
    static func main() throws {
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
            print("VoiceTypingCore checks passed")
        }
    }

    private static func expect(_ actual: String, _ expected: String) {
        precondition(actual == expected, "Expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
    }
}
