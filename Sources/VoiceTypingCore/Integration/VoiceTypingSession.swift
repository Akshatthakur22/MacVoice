import Foundation
import TypingCore

public enum VoiceTypingState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case stopping
    case failed(String)
}

public enum VoiceTypingSessionError: Error, LocalizedError {
    case invalidState(VoiceTypingState)
    case audioBufferOverrun

    public var errorDescription: String? {
        switch self {
        case .invalidState(let state): return "Cannot start voice typing while in state \(state)."
        case .audioBufferOverrun: return "Audio processing fell behind microphone capture; the session was stopped to avoid silently dropping speech."
        }
    }
}

/// Connects microphone frames, a replaceable recognizer, stable transcript
/// deltas, and the existing append-only TypingCore API.
public actor VoiceTypingSession {
    public private(set) var state: VoiceTypingState = .idle
    public var onStateChange: ((VoiceTypingState) -> Void)?

    private let audioCapture: AudioCapture
    private let recognizer: any SpeechRecognizer
    private let typingEngine: TypingEngine
    private var reconciler = TranscriptReconciler()
    private var audioContinuation: AsyncStream<PCMFrame>.Continuation?
    private var updateContinuation: AsyncStream<SpeechRecognitionUpdate>.Continuation?
    private var audioTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(audioCapture: AudioCapture, recognizer: any SpeechRecognizer, typingEngine: TypingEngine) {
        self.audioCapture = audioCapture
        self.recognizer = recognizer
        self.typingEngine = typingEngine
    }

    public func setStateChangeHandler(_ handler: ((VoiceTypingState) -> Void)?) {
        onStateChange = handler
    }

    /// Loads/starts recognition first, then starts microphone capture. The host
    /// must request microphone permission before calling this method.
    public func start() async throws {
        guard state == .idle else {
            throw VoiceTypingSessionError.invalidState(state)
        }
        generation &+= 1
        let ticket = generation
        setState(.starting)
        reconciler.reset()

        let (audioStream, audioStreamContinuation) = AsyncStream<PCMFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(32)
        )
        let (updateStream, updateStreamContinuation) = AsyncStream<SpeechRecognitionUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        audioContinuation = audioStreamContinuation
        updateContinuation = updateStreamContinuation

        audioTask = Task { [weak self] in
            for await frame in audioStream {
                guard let self else { return }
                do {
                    try await self.consume(frame)
                } catch {
                    await self.fail(error)
                    return
                }
            }
        }
        updateTask = Task { [weak self] in
            for await update in updateStream {
                await self?.receive(update)
            }
        }

        recognizer.onUpdate = { updateStreamContinuation.yield($0) }
        recognizer.onError = { [weak self] error in
            Task { await self?.fail(error) }
        }
        audioCapture.onError = { [weak self] error in
            Task { await self?.fail(error) }
        }
        audioCapture.onFrame = { [weak self] frame in
            guard case .dropped = audioStreamContinuation.yield(frame) else { return }
            Task { await self?.fail(VoiceTypingSessionError.audioBufferOverrun) }
        }

        do {
            try await recognizer.start()
            guard generation == ticket, state == .starting else {
                await recognizer.stop()
                return
            }
            try audioCapture.start()
            guard generation == ticket, state == .starting else {
                audioCapture.stop()
                await recognizer.stop()
                return
            }
            setState(.listening)
        } catch {
            audioCapture.stop()
            audioStreamContinuation.finish()
            await recognizer.stop()
            updateStreamContinuation.finish()
            await audioTask?.value
            await updateTask?.value
            clearStreams()
            if generation == ticket { setState(.failed(error.localizedDescription)) }
            throw error
        }
    }

    /// Stops capture, drains already delivered frames, lets the recognizer emit
    /// its final update, then drains transcript updates. Existing TypingCore
    /// output is allowed to finish; this does not retract posted events.
    public func stop() async {
        guard state == .listening || state == .starting || isFailed else { return }
        generation &+= 1
        setState(.stopping)
        audioCapture.stop()
        audioContinuation?.finish()
        await audioTask?.value
        await recognizer.stop()
        updateContinuation?.finish()
        await updateTask?.value
        clearStreams()
        reconciler.reset()
        if !isFailed { setState(.idle) }
    }

    /// Drains any failed session and returns it to Idle so the host can retry.
    public func resetFailure() async {
        guard isFailed else { return }
        await stop()
        if isFailed { setState(.idle) }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func consume(_ frame: PCMFrame) async throws {
        try await recognizer.consume(frame)
    }

    private func receive(_ update: SpeechRecognitionUpdate) {
        do {
            let stableDelta = try reconciler.consume(update)
            guard !stableDelta.isEmpty else { return }
            typingEngine.append(stableDelta) { [weak self] result in
                guard case .failure(let error) = result else { return }
                Task { await self?.fail(error) }
            }
        } catch {
            Task { await fail(error) }
        }
    }

    private func fail(_ error: Error) async {
        guard state != .failed(error.localizedDescription), state != .idle else { return }
        setState(.failed(error.localizedDescription))
        audioCapture.stop()
        audioContinuation?.finish()
        await recognizer.stop()
        updateContinuation?.finish()
    }

    private func clearStreams() {
        audioContinuation = nil
        updateContinuation = nil
        audioTask = nil
        updateTask = nil
        audioCapture.onFrame = nil
        audioCapture.onError = nil
        recognizer.onUpdate = nil
        recognizer.onError = nil
    }

    private func setState(_ newState: VoiceTypingState) {
        state = newState
        onStateChange?(newState)
    }
}
