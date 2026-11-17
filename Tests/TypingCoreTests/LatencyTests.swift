import Foundation
import Testing
@testable import TypingCore
@testable import VoiceTypingCore

@Suite("LatencyTests")
struct LatencyTests {
    private func actions(_ text: String, units: Int, newline: NewlineBehavior = .enter) -> [InputAction] {
        var result: [InputAction] = []
        TextEncoder.forEachAction(in: text, newlineBehavior: newline, maxUnitsPerEvent: units) { result.append($0) }
        return result
    }

    // MARK: Grouped key events

    @Test func groupsPrintableTextUpToTwentyUnits() {
        let text = "Hello there, this is a longer sentence."
        let grouped = actions(text, units: 20)
        #expect(grouped == [.unicode("Hello there, this is"), .unicode(" a longer sentence.")])
        #expect(grouped.map(\.insertedCharacterCount).reduce(0, +) == text.count)
    }

    @Test func oneUnitKeepsCharacterAtATime() {
        #expect(actions("abc", units: 1) == [.unicode("a"), .unicode("b"), .unicode("c")])
    }

    @Test func lineBreaksAndTabsStaySeparateKeys() {
        #expect(actions("Hi\nthere\tyou\u{2028}ok", units: 20)
                == [.unicode("Hi"), .keyCode(36), .unicode("there"), .unicode("\t"), .unicode("you"), .shiftEnter, .unicode("ok")])
    }

    @Test func neverSplitsAGrapheme() {
        // Each family emoji is 11 UTF-16 units; two cannot share a 20-unit event.
        let family = "👨‍👩‍👧‍👦"
        let grouped = actions(family + family + "e\u{301}", units: 20)
        #expect(grouped == [.unicode(family), .unicode(family + "e\u{301}")])
        #expect(grouped.map(\.insertedCharacterCount) == [1, 2])
    }

    // MARK: Segment ends release text immediately

    @Test func reconcilerReleasesLastCharacterAtSegmentEnd() throws {
        var reconciler = TranscriptReconciler()
        #expect(try reconciler.consume(.init(hypothesis: "Done.", confirmedTranscript: "Done.")) == "Done")
        #expect(try reconciler.consume(.init(hypothesis: "Done.", confirmedTranscript: "Done.", endsSegment: true)) == ".")
    }

    @Test func polishedSentenceIsTypedWhenSegmentEnds() async {
        let output = RecordingOutput()
        let coordinator = PolishingCoordinator(
            engine: output, polisher: NativeSwiftTranscriptPolisher(locale: Locale(identifier: "en_US")), mode: .polished)
        await coordinator.begin()
        await coordinator.consume("Ship it today.", endsSegment: true)
        // Allow the coordinator's processing task to run, without calling finish().
        for _ in 0..<50 where output.texts.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(output.texts == ["Ship it today."])
    }
}

private final class RecordingOutput: TypingOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var texts: [String] { lock.withLock { recorded } }
    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {
        lock.withLock { recorded.append(text) }
    }
    func stop() {}
    func drain() async {}
}
