import Foundation
import TypingCore

/// Serializes phrase cleanup and TypingCore commits. Recognition can continue
/// while one phrase is being polished; phrases are committed in source order.
public actor PolishingCoordinator {
    private let engine: TypingEngine
    private let polisher: any TranscriptPolisher
    private let mode: PolishingMode
    private var buffer = PhraseBuffer()
    private var pending: [String] = []
    private var processing = false
    private var forceVerbatim = false
    private var generation: UInt64 = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    public var onError: ((Error) -> Void)?
    public var onTypingFailure: ((Error) -> Void)?
    public var onQueuePressure: (() -> Void)?

    public init(engine: TypingEngine, polisher: any TranscriptPolisher, mode: PolishingMode) {
        self.engine = engine
        self.polisher = polisher
        self.mode = mode
    }

    public func begin() { generation &+= 1; buffer = PhraseBuffer(); pending.removeAll(); forceVerbatim = false }
    public func setQueuePressureHandler(_ handler: (() -> Void)?) { onQueuePressure = handler }
    public func setErrorHandler(_ handler: ((Error) -> Void)?) { onError = handler }
    public func setTypingFailureHandler(_ handler: ((Error) -> Void)?) { onTypingFailure = handler }

    public func consume(_ delta: String) {
        guard !delta.isEmpty else { return }
        if mode == .verbatim {
            engine.append(delta) { [weak self] result in
                if case .failure(let error) = result { Task { await self?.onTypingFailure?(error) } }
            }
            return
        }
        enqueue(buffer.append(delta))
    }

    public func finish() async {
        if mode == .polished, let tail = buffer.flush() { enqueue([tail]) }
        await drain()
    }

    private func enqueue(_ phrases: [String]) {
        guard !phrases.isEmpty else { return }
        pending.append(contentsOf: phrases)
        if pending.count > 16 {
            // Preserve every confirmed phrase and order. Stop accepting more
            // audio; queued phrases use originals if inference is falling behind.
            forceVerbatim = true
            onQueuePressure?()
        }
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !processing, !pending.isEmpty else { completeDrainIfNeeded(); return }
        processing = true
        let phrase = pending.removeFirst()
        let ticket = generation
        Task { await process(phrase, ticket: ticket) }
    }

    private func process(_ phrase: String, ticket: UInt64) async {
        var output = phrase
        if !forceVerbatim {
            do { output = try await polisher.polish(phrase) }
            catch {
                forceVerbatim = true
                onError?(error)
            }
        }
        guard ticket == generation else { processing = false; processNextIfNeeded(); return }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = phrase }
        engine.append(output) { [weak self] result in
            if case .failure(let error) = result { Task { await self?.onTypingFailure?(error) } }
        }
        processing = false
        processNextIfNeeded()
    }

    private func drain() async {
        if !processing && pending.isEmpty { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func completeDrainIfNeeded() {
        guard !processing, pending.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
