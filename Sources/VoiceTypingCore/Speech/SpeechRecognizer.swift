import Foundation

/// Cumulative transcript information from one recognition session.
/// `confirmedTranscript` must be an exact, append-only prefix promised by the
/// recognizer. `hypothesis` may change freely and must never be typed directly.
public struct SpeechRecognitionUpdate: Sendable, Equatable {
    public let hypothesis: String
    public let confirmedTranscript: String
    public let isFinal: Bool

    public init(hypothesis: String, confirmedTranscript: String, isFinal: Bool = false) {
        self.hypothesis = hypothesis
        self.confirmedTranscript = confirmedTranscript
        self.isFinal = isFinal
    }
}

/// Replaceable local or remote recognition backend contract. A local backend
/// should keep audio processing on-device and report only confirmed text in
/// `confirmedTranscript`; the app may display `hypothesis` as ephemeral status.
public protocol SpeechRecognizer: AnyObject {
    var onUpdate: ((SpeechRecognitionUpdate) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start() async throws
    func consume(_ frame: PCMFrame) async throws
    func stop() async
}

public enum SpeechRecognizerError: Error, LocalizedError {
    case modelUnavailable(String)
    case modelLoadFailed(String)
    case unsupportedAudioFormat
    case inferenceFailed(String)
    case audioBufferOverrun
    case stopped

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let detail): return "Speech model unavailable: \(detail)"
        case .modelLoadFailed(let detail): return "Could not load speech model: \(detail)"
        case .unsupportedAudioFormat: return "The recognizer cannot process the supplied PCM format."
        case .inferenceFailed(let detail): return "Speech recognition failed: \(detail)"
        case .audioBufferOverrun: return "The speech analyzer could not keep up with incoming audio."
        case .stopped: return "Speech recognition has stopped."
        }
    }
}
