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
    public var onWarning: ((String) -> Void)?

    private enum CleanupResult {
        case stopped
        case failed(String)
    }

    private let audioCapture: any AudioCapturing
    private let recognizer: any SpeechRecognizer
    private let typingOutput: any TypingOutput
    private let polishingMode: PolishingMode
    private let polishingCoordinator: PolishingCoordinator
    private var reconciler = TranscriptReconciler()
    private var audioContinuation: AsyncStream<PCMFrame>.Continuation?
    private var updateContinuation: AsyncStream<SpeechRecognitionUpdate>.Continuation?
    private var audioTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var recognizerStartTask: Task<Void, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupGeneration: UInt64 = 0
    private var cleanupResult: CleanupResult?
    private var generation: UInt64 = 0

    public init(audioCapture: any AudioCapturing, recognizer: any SpeechRecognizer, typingEngine: any TypingOutput,
                polisher: any TranscriptPolisher = PassthroughTranscriptPolisher(),
                polishingMode: PolishingMode = .verbatim) {
        self.audioCapture = audioCapture
        self.recognizer = recognizer
        self.typingOutput = typingEngine
        self.polishingMode = polishingMode
        self.polishingCoordinator = PolishingCoordinator(engine: typingEngine, polisher: polisher, mode: polishingMode)
    }

    public func setStateChangeHandler(_ handler: ((VoiceTypingState) -> Void)?) {
        onStateChange = handler
    }

    public func setWarningHandler(_ handler: ((String) -> Void)?) { onWarning = handler }

    /// Starts recognition before capture. The host must request microphone
    /// permission first. Concurrent stop cancels and joins recognizer startup.
    public func start() async throws {
        guard state == .idle, cleanupTask == nil else {
            throw VoiceTypingSessionError.invalidState(state)
        }
        generation &+= 1
        let ticket = generation
        setState(.starting)
        reconciler.reset()
        if polishingMode == .polished {
            await polishingCoordinator.begin()
            await polishingCoordinator.setErrorHandler { [weak self] error in
                Task { await self?.reportWarning(error.localizedDescription) }
            }
            await polishingCoordinator.setTypingFailureHandler { [weak self] error in
                Task { await self?.fail(error, sessionGeneration: ticket) }
            }
            await polishingCoordinator.setQueuePressureHandler { [weak self] in
                Task { await self?.fail(VoiceTypingSessionError.audioBufferOverrun, sessionGeneration: ticket) }
            }
        }

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
                    // Cleanup runs in another task so it can cancel/join this consumer.
                    Task { await self.fail(error, sessionGeneration: ticket) }
                    return
                }
            }
        }
        updateTask = Task { [weak self] in
            for await update in updateStream {
                await self?.receive(update, sessionGeneration: ticket)
            }
        }

        recognizer.onUpdate = { updateStreamContinuation.yield($0) }
        recognizer.onError = { [weak self] error in
            Task { await self?.fail(error, sessionGeneration: ticket) }
        }
        audioCapture.onError = { [weak self] error in
            Task { await self?.fail(error, sessionGeneration: ticket) }
        }
        audioCapture.onFrame = { [weak self] frame in
            guard case .dropped = audioStreamContinuation.yield(frame) else { return }
            Task { await self?.fail(VoiceTypingSessionError.audioBufferOverrun, sessionGeneration: ticket) }
        }

        let startup = Task { try await recognizer.start() }
        recognizerStartTask = startup
        do {
            try await startup.value
            if generation == ticket { recognizerStartTask = nil }
            guard generation == ticket, state == .starting, cleanupTask == nil else { return }
            try audioCapture.start()
            guard generation == ticket, state == .starting, cleanupTask == nil else {
                audioCapture.stop()
                return
            }
            setState(.listening)
        } catch {
            if generation == ticket { recognizerStartTask = nil }
            if cleanupTask == nil {
                await fail(error, sessionGeneration: ticket)
            } else {
                await waitForCleanup()
            }
            throw error
        }
    }

    /// Stops capture and drains delivered audio, final recognition updates,
    /// Polished work, and queued typing events before returning to Idle.
    public func stop() async {
        if cleanupTask != nil {
            await waitForCleanup()
            return
        }
        guard state == .listening || state == .starting else { return }
        let (task, cleanupID) = beginCleanup(result: .stopped)
        await task.value
        finishCleanup(cleanupID)
    }

    /// Joins any active cleanup before resetting a failed session to Idle.
    public func resetFailure() async {
        if cleanupTask != nil { await waitForCleanup() }
        guard isFailed, cleanupTask == nil else { return }
        reconciler.reset()
        setState(.idle)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func consume(_ frame: PCMFrame) async throws {
        try await recognizer.consume(frame)
    }

    private func receive(_ update: SpeechRecognitionUpdate, sessionGeneration: UInt64) async {
        guard generation == sessionGeneration else { return }
        do {
            let stableDelta = try reconciler.consume(update)
            guard !stableDelta.isEmpty else { return }
            if polishingMode == .verbatim {
                typingOutput.append(stableDelta, completion: { [weak self] result in
                    guard case .failure(let error) = result else { return }
                    Task { await self?.fail(error, sessionGeneration: sessionGeneration) }
                })
            } else {
                await polishingCoordinator.consume(stableDelta)
            }
        } catch {
            Task { await fail(error, sessionGeneration: sessionGeneration) }
        }
    }

    private func fail(_ error: Error, sessionGeneration: UInt64) async {
        guard generation == sessionGeneration,
              cleanupTask == nil,
              state != .idle,
              state != .stopping,
              !isFailed else { return }
        let (task, cleanupID) = beginCleanup(result: .failed(error.localizedDescription))
        await task.value
        finishCleanup(cleanupID)
    }

    /// Installs exactly one teardown task before suspending the actor. All
    /// stop/reset/failure callers join that task instead of repeating cleanup.
    private func beginCleanup(result: CleanupResult) -> (Task<Void, Never>, UInt64) {
        if let cleanupTask { return (cleanupTask, cleanupGeneration) }
        cleanupGeneration &+= 1
        let cleanupID = cleanupGeneration
        cleanupResult = result
        switch result {
        case .stopped: setState(.stopping)
        case .failed(let message): setState(.failed(message))
        }

        audioCapture.stop()
        audioContinuation?.finish()
        let startup = recognizerStartTask
        let audio = audioTask
        let updates = updateTask
        let updateStream = updateContinuation
        let recognizer = self.recognizer
        let coordinator = polishingCoordinator
        let typingOutput = self.typingOutput
        let shouldFinishPolishing = polishingMode == .polished
        let shouldCancelAudio: Bool
        switch result {
        case .stopped: shouldCancelAudio = false
        case .failed: shouldCancelAudio = true
        }

        let task = Task {
            startup?.cancel()
            if shouldCancelAudio { audio?.cancel() }
            if let startup { _ = try? await startup.value }
            await audio?.value
            await recognizer.stop()
            updateStream?.finish()
            await updates?.value
            if shouldFinishPolishing { await coordinator.finish() }
            if shouldCancelAudio { typingOutput.stop() }
            await typingOutput.drain()
        }
        cleanupTask = task
        return (task, cleanupID)
    }

    private func waitForCleanup() async {
        guard let task = cleanupTask else { return }
        let cleanupID = cleanupGeneration
        await task.value
        finishCleanup(cleanupID)
    }

    private func finishCleanup(_ cleanupID: UInt64) {
        guard cleanupGeneration == cleanupID, cleanupTask != nil else { return }
        let result = cleanupResult
        cleanupTask = nil
        cleanupResult = nil
        recognizerStartTask = nil
        clearStreams()
        reconciler.reset()
        switch result {
        case .stopped: setState(.idle)
        case .failed(let message): setState(.failed(message))
        case nil: break
        }
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

    private func reportWarning(_ message: String) { onWarning?(message) }
}
