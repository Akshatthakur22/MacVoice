import Foundation
import Testing
@testable import VoiceTypingCore
import TypingCore

@Suite("SessionLifecycleTests")
struct SessionLifecycleTests {
    @MainActor
    @Test func productionStartCoordinatorRejectsDuplicateAndRetriesAfterPreparationFailure() async {
        let coordinator = SessionStartCoordinator()
        let preparationEntered = AsyncExpectation()
        let preparationFailure = AsyncExpectation()
        var resumePreparation: (() -> Void)?
        var reportedError: Error?

        let started = coordinator.begin(operation: {
            Task { await preparationEntered.fulfill() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resumePreparation = { continuation.resume() }
            }
            throw TestFailure.preparation
        }, onFailure: { error in
            reportedError = error
            Task { await preparationFailure.fulfill() }
        })
        #expect(started)
        await preparationEntered.wait()
        #expect(!coordinator.begin(operation: {}, onFailure: { _ in }))

        resumePreparation?()
        await preparationFailure.wait()
        #expect(reportedError?.localizedDescription == "controlled preparation failure")
        await coordinator.waitForCurrentOperation()
        #expect(!coordinator.isRunning)

        let retryCompleted = AsyncExpectation()
        let retryStarted = coordinator.begin(operation: {
            Task { await retryCompleted.fulfill() }
        }, onFailure: { _ in
            Issue.record("retry failed")
        })
        #expect(retryStarted)
        await retryCompleted.wait()
        await coordinator.waitForCurrentOperation()
        #expect(!coordinator.isRunning)
    }

    @MainActor
    @Test func productionStartCoordinatorCancellationReleasesGate() async {
        let coordinator = SessionStartCoordinator()
        let operationEntered = AsyncExpectation()
        let started = coordinator.begin(operation: {
            Task { await operationEntered.fulfill() }
            try await Task.sleep(for: .seconds(30))
        }, onFailure: { _ in
            Issue.record("cancellation should not be reported as setup failure")
        })
        #expect(started)
        await operationEntered.wait()

        await coordinator.cancelAndWait()
        #expect(!coordinator.isRunning)
        let restarted = coordinator.begin(operation: {}, onFailure: { _ in Issue.record("retry failed") })
        #expect(restarted)
        await coordinator.waitForCurrentOperation()
    }

    @Test func resetJoinsSuspendedFailureCleanupInsteadOfStartingSecondTeardown() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer(suspendStop: true)
        let session = makeSession(capture: capture, recognizer: recognizer)
        let stopEntered = AsyncExpectation()
        recognizer.onStopStarted = {
            Task { await stopEntered.fulfill() }
        }

        try await session.start()
        recognizer.fail(SpeechRecognizerError.inferenceFailed("controlled failure"))
        await stopEntered.wait()

        let reset = Task { await session.resetFailure() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(recognizer.stopCount == 1, "reset must join failure cleanup")
        var state = await session.state
        #expect(state == .failed("Speech recognition failed: controlled failure"))

        recognizer.resumeStop()
        await reset.value
        state = await session.state
        #expect(state == .idle)
        #expect(recognizer.stopCount == 1)

        try await session.start()
        state = await session.state
        #expect(state == .listening)
        await session.stop()
    }

    @Test func delayedPriorSessionErrorCannotFailRestartedSession() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer()
        let session = makeSession(capture: capture, recognizer: recognizer)

        try await session.start()
        let priorSessionHandler = recognizer.onError
        await session.stop()
        try await session.start()
        priorSessionHandler?(SpeechRecognizerError.inferenceFailed("stale callback"))

        try await Task.sleep(for: .milliseconds(80))
        let state = await session.state
        #expect(state == .listening)
        #expect(recognizer.stopCount == 1)
        await session.stop()
    }

    @Test func startupFailureCanBeRetriedThenStoppedAndRestarted() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer(failFirstStart: true)
        let session = makeSession(capture: capture, recognizer: recognizer)

        do {
            try await session.start()
            Issue.record("first start should fail")
        } catch {
            #expect(error.localizedDescription == "controlled startup failure")
        }
        var state = await session.state
        #expect(state == .failed("controlled startup failure"))

        await session.resetFailure()
        state = await session.state
        #expect(state == .idle)
        try await session.start()
        state = await session.state
        #expect(state == .listening)
        await session.stop()
        state = await session.state
        #expect(state == .idle)

        try await session.start()
        state = await session.state
        #expect(state == .listening)
        await session.stop()
        state = await session.state
        #expect(state == .idle)
        #expect(recognizer.startCount == 3)
    }

    @Test func normalStopWaitsForPendingTypingAndFailureCancelsUnpostedTyping() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer()
        let typing = ControlledTypingOutput()
        let session = makeSession(capture: capture, recognizer: recognizer, typing: typing)
        let appended = AsyncExpectation()
        typing.onAppend = { Task { await appended.fulfill() } }
        let drainStarted = AsyncExpectation()
        typing.onDrain = { Task { await drainStarted.fulfill() } }

        try await session.start()
        recognizer.send(.init(hypothesis: "hello", confirmedTranscript: "hello", isFinal: true))
        await appended.wait()
        let stop = Task { await session.stop() }
        await drainStarted.wait()
        var state = await session.state
        #expect(state == .stopping)
        #expect(typing.stopCount == 0, "normal stop drains rather than cancels queued output")
        typing.resumeDrain()
        await stop.value
        state = await session.state
        #expect(state == .idle)

        let failureDrainStarted = AsyncExpectation()
        typing.onDrain = { Task { await failureDrainStarted.fulfill() } }
        let failureAppended = AsyncExpectation()
        typing.onAppend = { Task { await failureAppended.fulfill() } }
        let failureComplete = AsyncExpectation()
        await session.setStateChangeHandler { newState in
            if newState == .failed("Speech recognition failed: stop output") {
                Task { await failureComplete.fulfill() }
            }
        }
        try await session.start()
        recognizer.send(.init(hypothesis: "again", confirmedTranscript: "again", isFinal: true))
        await failureAppended.wait()
        recognizer.fail(SpeechRecognizerError.inferenceFailed("stop output"))
        await failureDrainStarted.wait()
        #expect(typing.stopCount == 1, "failure cancels text not yet posted")
        typing.resumeDrain()
        await failureComplete.wait()
        state = await session.state
        #expect(state == .failed("Speech recognition failed: stop output"))
    }

    @Test func failureCancelsSuspendedConsumeBeforeRecognizerStop() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer(suspendConsumption: true)
        let session = makeSession(capture: capture, recognizer: recognizer)
        let consumeStarted = AsyncExpectation()
        let consumeReturned = AsyncExpectation()
        let recognizerStopped = AsyncExpectation()
        recognizer.onConsumeStarted = { Task { await consumeStarted.fulfill() } }
        recognizer.onConsumeReturned = { Task { await consumeReturned.fulfill() } }
        recognizer.onStopStarted = { Task { await recognizerStopped.fulfill() } }

        try await session.start()
        capture.emit(testFrame)
        await consumeStarted.wait()
        recognizer.fail(SpeechRecognizerError.inferenceFailed("controlled failure"))
        await consumeReturned.wait()
        await recognizerStopped.wait()
        #expect(recognizer.consumeReturnOrder < recognizer.stopOrder)
        let state = await session.state
        #expect(state == .failed("Speech recognition failed: controlled failure"))
    }

    private var testFrame: PCMFrame {
        PCMFrame(samples: [0.1], sampleRate: 16_000, channelCount: 1, frameCount: 1,
                 deliveryUptimeNanoseconds: 1)
    }

    private func makeSession(capture: MockAudioCapture, recognizer: LifecycleSpeechRecognizer,
                             typing: any TypingOutput = TypingEngine(interCharacterDelay: 0, newlineBehavior: .omit)) -> VoiceTypingSession {
        VoiceTypingSession(audioCapture: capture, recognizer: recognizer, typingEngine: typing)
    }
}

actor AsyncExpectation {
    private var fulfilled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fulfill() {
        if !fulfilled {
            fulfilled = true
            let list = waiters
            waiters.removeAll()
            for w in list { w.resume() }
        }
    }

    func wait() async {
        if fulfilled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    var isFulfilled: Bool { fulfilled }
}

private final class MockAudioCapture: AudioCapturing {
    var onFrame: ((PCMFrame) -> Void)?
    var onError: ((AudioCaptureError) -> Void)?
    func start() throws {}
    func stop() {}
    func emit(_ frame: PCMFrame) { onFrame?(frame) }
}

private final class LifecycleSpeechRecognizer: SpeechRecognizer {
    var onUpdate: ((SpeechRecognitionUpdate) -> Void)?
    var onError: ((Error) -> Void)?
    var onConsumeStarted: (() -> Void)?
    var onConsumeReturned: (() -> Void)?
    var onStopStarted: (() -> Void)?
    private let suspendConsumption: Bool
    private let suspendStop: Bool
    private let failFirstStart: Bool
    private let lock = NSLock()
    private var consumeContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var consumeCancelled = false
    private var ordering = 0
    private(set) var consumeReturnOrder = 0
    private(set) var stopOrder = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(suspendConsumption: Bool = false, suspendStop: Bool = false, failFirstStart: Bool = false) {
        self.suspendConsumption = suspendConsumption
        self.suspendStop = suspendStop
        self.failFirstStart = failFirstStart
    }

    func start() async throws {
        startCount += 1
        resetConsumeCancellation()
        if failFirstStart && startCount == 1 { throw TestFailure.startup }
    }

    func consume(_ frame: PCMFrame) async throws {
        guard suspendConsumption else { return }
        onConsumeStarted?()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    let alreadyCancelled = consumeCancelled
                    if !alreadyCancelled { consumeContinuation = continuation }
                    lock.unlock()
                    if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                self.cancelSuspendedConsume()
            }
        } catch is CancellationError {
            recordConsumeReturned()
            onConsumeReturned?()
            throw CancellationError()
        }
        recordConsumeReturned()
        onConsumeReturned?()
    }

    func stop() async {
        lock.lock()
        stopCount += 1
        ordering += 1
        stopOrder = ordering
        lock.unlock()
        onStopStarted?()
        if suspendStop {
            await withCheckedContinuation { continuation in stopContinuation = continuation }
        }
    }

    func send(_ update: SpeechRecognitionUpdate) { onUpdate?(update) }
    func fail(_ error: Error) { onError?(error) }

    func resumeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }

    private func cancelSuspendedConsume() {
        lock.lock()
        consumeCancelled = true
        let continuation = consumeContinuation
        consumeContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func resetConsumeCancellation() {
        lock.lock()
        consumeCancelled = false
        lock.unlock()
    }

    private func recordConsumeReturned() {
        lock.lock()
        ordering += 1
        consumeReturnOrder = ordering
        lock.unlock()
    }
}

private final class ControlledTypingOutput: TypingOutput {
    var onAppend: (() -> Void)?
    var onDrain: (() -> Void)?
    private(set) var appended: [String] = []
    private(set) var stopCount = 0
    private var drainContinuation: CheckedContinuation<Void, Never>?

    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {
        appended.append(text)
        onAppend?()
    }

    func stop() { stopCount += 1 }

    func drain() async {
        onDrain?()
        await withCheckedContinuation { drainContinuation = $0 }
    }

    func resumeDrain() {
        let continuation = drainContinuation
        drainContinuation = nil
        continuation?.resume()
    }
}

private enum TestFailure: Error, LocalizedError {
    case startup
    case preparation
    var errorDescription: String? {
        switch self {
        case .startup: "controlled startup failure"
        case .preparation: "controlled preparation failure"
        }
    }
}
