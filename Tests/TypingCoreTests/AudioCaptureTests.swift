import Testing
@testable import VoiceTypingCore

@Suite("AudioCaptureTests")
struct AudioCaptureTests {
    @Test func pcmFramePreservesSamplesAndFormatMetadata() {
        let frame = PCMFrame(
            samples: [0.25, -0.25, 0.5, -0.5],
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 2,
            deliveryUptimeNanoseconds: 123
        )

        #expect(frame.samples == [0.25, -0.25, 0.5, -0.5])
        #expect(frame.sampleRate == 48_000)
        #expect(frame.channelCount == 2)
        #expect(frame.frameCount == 2)
        #expect(frame.deliveryUptimeNanoseconds == 123)
    }
}

