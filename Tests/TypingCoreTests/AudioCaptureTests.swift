import XCTest
@testable import VoiceTypingCore

final class AudioCaptureTests: XCTestCase {
    func testPCMFramePreservesSamplesAndFormatMetadata() {
        let frame = PCMFrame(
            samples: [0.25, -0.25, 0.5, -0.5],
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 2,
            deliveryUptimeNanoseconds: 123
        )

        XCTAssertEqual(frame.samples, [0.25, -0.25, 0.5, -0.5])
        XCTAssertEqual(frame.sampleRate, 48_000)
        XCTAssertEqual(frame.channelCount, 2)
        XCTAssertEqual(frame.frameCount, 2)
        XCTAssertEqual(frame.deliveryUptimeNanoseconds, 123)
    }
}
