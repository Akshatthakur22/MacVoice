import Foundation
@testable import VoiceTypingCore

final class MockSpeechRecognizer: SpeechRecognizer {
    var onUpdate: ((SpeechRecognitionUpdate) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var started = false
    private(set) var consumedFrames: [PCMFrame] = []

    func start() async throws {
        started = true
    }

    func consume(_ frame: PCMFrame) async throws {
        guard started else { throw SpeechRecognizerError.stopped }
        consumedFrames.append(frame)
    }

    func stop() async {
        started = false
    }

    func send(_ update: SpeechRecognitionUpdate) {
        onUpdate?(update)
    }

    func fail(_ error: Error) {
        onError?(error)
    }
}
