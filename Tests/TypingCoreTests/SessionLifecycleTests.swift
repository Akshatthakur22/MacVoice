import XCTest
@testable import VoiceTypingCore
import TypingCore

final class SessionLifecycleTests: XCTestCase {
    @MainActor
    func testProductionStartCoordinatorRejectsDuplicateAndRetriesAfterPreparationFailure() async {
        let coordinator = SessionStartCoordinator()
        let preparationEntered = expectation(description: "production preparation entered")
        let preparationFailure = expectation(description: "preparation error reported")
        var resumePreparation: (() -> Void)?

        XCTAssertTrue(coordinator.begin(operation: {
            preparationEntered.fulfill()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resumePreparation = { continuation.resume() }
            }
            throw TestFailure.preparation
        }, onFailure: { error in
            XCTAssertEqual(error.localizedDescription, "controlled preparation failure")
            preparationFailure.fulfill()
        }))
        await fulfillment(of: [preparationEntered], timeout: 2)
        XCTAssertFalse(coordinator.begin(operation: {}, onFailure: { _ in }))

        resumePreparation?()
        await fulfillment(of: [preparationFailure], timeout: 2)
        await coordinator.waitForCurrentOperation()
        XCTAssertFalse(coordinator.isRunning)

        let retryCompleted = expectation(description: "retry completed")
        XCTAssertTrue(coordinator.begin(operation: { retryCompleted.fulfill() }, onFailure: { _ in XCTFail("retry failed") }))
        await fulfillment(of: [retryCompleted], timeout: 2)
        await coordinator.waitForCurrentOperation()
        XCTAssertFalse(coordinator.isRunning)
    }

    @MainActor
    func testProductionStartCoordinatorCancellationReleasesGate() async {
        let coordinator = SessionStartCoordinator()
        let operationEntered = expectation(description: "cancellable preparation entered")
        XCTAssertTrue(coordinator.begin(operation: {
            operationEntered.fulfill()
            try await Task.sleep(for: .seconds(30))
        }, onFailure: { _ in XCTFail("cancellation should not be reported as setup failure") }))
        await fulfillment(of: [operationEntered], timeout: 2)

        await coordinator.cancelAndWait()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(coordinator.begin(operation: {}, onFailure: { _ in XCTFail("retry failed") }))
        await coordinator.waitForCurrentOperation()
    }

    func testResetJoinsSuspendedFailureCleanupInsteadOfStartingSecondTeardown() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer(suspendStop: true)
        let session = makeSession(capture: capture, recognizer: recognizer)
        let stopEntered = expectation(description: "shared cleanup reached recognizer stop")
        recognizer.onStopStarted = { stopEntered.fulfill() }

        try await session.start()
        recognizer.fail(SpeechRecognizerError.inferenceFailed("controlled failure"))
        await fulfillment(of: [stopEntered], timeout: 2)

        let reset = Task { await session.resetFailure() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(recognizer.stopCount, 1, "reset must join failure cleanup")
        var state = await session.state
        XCTAssertEqual(state, .failed("Speech recognition failed: controlled failure"))

        recognizer.resumeStop()
        await reset.value
        state = await session.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(recognizer.stopCount, 1)

        try await session.start()
        state = await session.state
        XCTAssertEqual(state, .listening)
        await session.stop()
    }

    func testDelayedPriorSessionErrorCannotFailRestartedSession() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer()
        let session = makeSession(capture: capture, recognizer: recognizer)

        try await session.start()
        let priorSessionHandler = recognizer.onError
        await session.stop()
        try await session.start()
        priorSessionHandler?(SpeechRecognizerError.inferenceFailed("stale callback"))

        let staleFailure = expectation(description: "stale callback must be ignored")
        staleFailure.isInverted = true
        await fulfillment(of: [staleFailure], timeout: 0.08)
        let state = await session.state
        XCTAssertEqual(state, .listening)
        XCTAssertEqual(recognizer.stopCount, 1)
        await session.stop()
    }

    func testStartupFailureCanBeRetriedThenStoppedAndRestarted() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer(failFirstStart: true)
        let session = makeSession(capture: capture, recognizer: recognizer)

        do {
            try await session.start()
            XCTFail("first start should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "controlled startup failure")
        }
        var state = await session.state
        XCTAssertEqual(state, .failed("controlled startup failure"))

        await session.resetFailure()
        state = await session.state
        XCTAssertEqual(state, .idle)
        try await session.start()
        state = await session.state
        XCTAssertEqual(state, .listening)
        await session.stop()
        state = await session.state
        XCTAssertEqual(state, .idle)

        try await session.start()
        state = await session.state
        XCTAssertEqual(state, .listening)
        await session.stop()
        state = await session.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(recognizer.startCount, 3)
    }

    func testNormalStopWaitsForPendingTypingAndFailureCancelsUnpostedTyping() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer()
        let typing = ControlledTypingOutput()
        let session = makeSession(capture: capture, recognizer: recognizer, typing: typing)
        let appended = expectation(description: "confirmed transcript queued for typing")
        typing.onAppend = { appended.fulfill() }
        let drainStarted = expectation(description: "normal stop drains typing")
        typing.onDrain = { drainStarted.fulfill() }

        try await session.start()
        recognizer.send(.init(hypothesis: "hello", confirmedTranscript: "hello", isFinal: true))
        await fulfillment(of: [appended], timeout: 2)
        let stop = Task { await session.stop() }
        await fulfillment(of: [drainStarted], timeout: 2)
        var state = await session.state
        XCTAssertEqual(state, .stopping)
        XCTAssertEqual(typing.stopCount, 0, "normal stop drains rather than cancels queued output")
        typing.resumeDrain()
        await stop.value
        state = await session.state
        XCTAssertEqual(state, .idle)

        let failureDrainStarted = expectation(description: "failure cancels then drains typing")
        typing.onDrain = { failureDrainStarted.fulfill() }
        let failureAppended = expectation(description: "second session text queued")
        typing.onAppend = { failureAppended.fulfill() }
        let failureComplete = expectation(description: "failure state is reported")
        await session.setStateChangeHandler { newState in
            if newState == .failed("Speech recognition failed: stop output") { failureComplete.fulfill() }
        }
        try await session.start()
        recognizer.send(.init(hypothesis: "again", confirmedTranscript: "again", isFinal: true))
        await fulfillment(of: [failureAppended], timeout: 2)
        recognizer.fail(SpeechRecognizerError.inferenceFailed("stop output"))
        await fulfillment(of: [failureDrainStarted], timeout: 2)
        XCTAssertEqual(typing.stopCount, 1, "failure cancels text not yet posted")
        typing.resumeDrain()
        await fulfillment(of: [failureComplete], timeout: 2)
        state = await session.state
        XCTAssertEqual(state, .failed("Speech recognition failed: stop output"))
    }

    func testFailureCancelsSuspendedConsumeBeforeRecognizerStop() async throws {
        let capture = MockAudioCapture()
        let recognizer = LifecycleSpeechRecognizer(suspendConsumption: true)
        let session = makeSession(capture: capture, recognizer: recognizer)
        let consumeStarted = expectation(description: "audio consumption started")
        let consumeReturned = expectation(description: "cancelled consume returned")
        let recognizerStopped = expectation(description: "recognizer stopped after consume")
        recognizer.onConsumeStarted = { consumeStarted.fulfill() }
        recognizer.onConsumeReturned = { consumeReturned.fulfill() }
        recognizer.onStopStarted = { recognizerStopped.fulfill() }

        try await session.start()
        capture.emit(testFrame)
        await fulfillment(of: [consumeStarted], timeout: 2)
        recognizer.fail(SpeechRecognizerError.inferenceFailed("controlled failure"))
        await fulfillment(of: [consumeReturned, recognizerStopped], timeout: 2)
        XCTAssertLessThan(recognizer.consumeReturnOrder, recognizer.stopOrder)
        let state = await session.state
        XCTAssertEqual(state, .failed("Speech recognition failed: controlled failure"))
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
