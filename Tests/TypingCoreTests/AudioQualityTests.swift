import Foundation
import Testing
@testable import VoiceTypingCore
import TypingCore

@Suite("AudioQualityTests")
struct AudioQualityTests {
    /// Speech in the first moments after the shortcut (while the recognizer
    /// is still starting) must be transcribed, in order, not dropped.
    @Test func audioBeforeRecognizerIsReadIsKept() async throws {
        let capture = RecordingCapture()
        let recognizer = SlowStartRecognizer()
        let session = VoiceTypingSession(audioCapture: capture, recognizer: recognizer,
                                         typingEngine: NullTypingOutput())
        let starting = Task { try await session.start() }
        while !capture.isRunning { try await Task.sleep(for: .milliseconds(1)) }
        #expect(recognizer.consumed.isEmpty)
        for id in 1...3 { capture.emit(id: id) } // user already talking
        recognizer.finishStarting()
        try await starting.value
        capture.emit(id: 4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recognizer.consumed == [1, 2, 3, 4])
        #expect(await session.state == .listening)
        await session.stop()
        #expect(!capture.isRunning)
    }
}

// MARK: - Test doubles

private final class RecordingCapture: AudioCapturing, @unchecked Sendable {
    var onFrame: ((PCMFrame) -> Void)?
    var onError: ((AudioCaptureError) -> Void)?
    private let lock = NSLock()
    private var running = false
    var isRunning: Bool { lock.withLock { running } }
    func start() throws { lock.withLock { running = true } }
    func stop() { lock.withLock { running = false } }
    func emit(id: Int) {
        onFrame?(PCMFrame(samples: [Float(id)], sampleRate: 16_000, channelCount: 1, frameCount: 1, deliveryUptimeNanoseconds: 0))
    }
}

private final class SlowStartRecognizer: SpeechRecognizer, @unchecked Sendable {
    var onUpdate: ((SpeechRecognitionUpdate) -> Void)?
    var onError: ((Error) -> Void)?
    private let lock = NSLock()
    private var ids: [Int] = []
    private var ready: CheckedContinuation<Void, Never>?
    private var released = false
    var consumed: [Int] { lock.withLock { ids } }

    func start() async throws {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                ready = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func finishStarting() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { ready = nil }
            return ready
        }
        continuation?.resume()
    }
    func consume(_ frame: PCMFrame) async throws { lock.withLock { ids.append(Int(frame.samples[0])) } }
    func stop() async {}
}

private final class NullTypingOutput: TypingOutput, @unchecked Sendable {
    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {}
    func stop() {}
    func drain() async {}
}
