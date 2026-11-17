import Foundation
import TypingCore

/// Serializes phrase cleanup and TypingCore commits. Recognition can continue
/// while one phrase is being polished; phrases are committed in source order.
public actor PolishingCoordinator {
    private let engine: any TypingOutput
    private let polisher: any TranscriptPolisher
    private let mode: PolishingMode
    private var buffer = PhraseBuffer()
    private var pending: [String] = []
    private var processing = false
    private var forceVerbatim = false
    private var insertion = InsertionContext.unknown
    /// Text state this dictation has produced, used to decide whether the next
    /// phrase starts a sentence and to restore after "scratch that".
    private struct TypedState {
        var lastCharacter: Character?
        var lastVisibleCharacter: Character?
        var hasTypedPhrase = false
    }
    private var typed = TypedState()
    private var typedBeforeLastPhrase = TypedState()
    private var generation: UInt64 = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    public var onError: ((Error) -> Void)?
    public var onTypingFailure: ((Error) -> Void)?
    public var onQueuePressure: (() -> Void)?

    public init(engine: any TypingOutput, polisher: any TranscriptPolisher, mode: PolishingMode) {
        self.engine = engine
        self.polisher = polisher
        self.mode = mode
    }

    public func begin(context: InsertionContext = .unknown) {
        generation &+= 1
        buffer = PhraseBuffer()
        pending.removeAll()
        forceVerbatim = false
        insertion = context
        typed = TypedState()
        typedBeforeLastPhrase = TypedState()
    }
    public func setQueuePressureHandler(_ handler: (() -> Void)?) { onQueuePressure = handler }
    public func setErrorHandler(_ handler: ((Error) -> Void)?) { onError = handler }
    public func setTypingFailureHandler(_ handler: ((Error) -> Void)?) { onTypingFailure = handler }

    public func consume(_ delta: String) {
        guard !delta.isEmpty else { return }
        if mode == .verbatim {
            engine.append(delta, completion: { [weak self] result in
                if case .failure(let error) = result { Task { await self?.onTypingFailure?(error) } }
            })
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
        var result = PolishedPhrase(text: phrase)
        if !forceVerbatim {
            do { result = try await polisher.polishPhrase(phrase, context: polishContext()) }
            catch {
                forceVerbatim = true
                onError?(error)
            }
        }
        guard ticket == generation else { processing = false; processNextIfNeeded(); return }

        if result.retractsPreviousPhrase && typed.hasTypedPhrase {
            engine.retractLastAppend()
            typed = typedBeforeLastPhrase
            typed.hasTypedPhrase = false // one level of "scratch that"
        }

        var output = result.text
        // After a spoken "new line", the next phrase must not start with a space.
        if let last = typed.lastCharacter, last == "\n" || last == "\u{2028}" {
            output = String(output.drop(while: { $0 == " " || $0 == "\t" }))
        }
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typedBeforeLastPhrase = typed
            typed.lastCharacter = output.last
            typed.lastVisibleCharacter = output.last(where: { $0 != " " && $0 != "\t" })
            typed.hasTypedPhrase = true
            engine.append(output, completion: { [weak self] result in
                if case .failure(let error) = result { Task { await self?.onTypingFailure?(error) } }
            })
        }
        processing = false
        processNextIfNeeded()
    }

    private func polishContext() -> PolishContext {
        let startsSentence: Bool
        if let last = typed.lastVisibleCharacter {
            startsSentence = ".!?。！？।-\n\u{2028}".contains(last)
        } else {
            startsSentence = !insertion.continuesSentence
        }
        return PolishContext(startsSentence: startsSentence, isTerminal: insertion.isTerminal)
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
