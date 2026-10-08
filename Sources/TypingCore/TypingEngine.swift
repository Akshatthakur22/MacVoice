import CoreGraphics
import Foundation

/// How newline characters are delivered. CGEvent has no universal newline
/// operation: apps may treat either Unicode LF or Return as a submit command.
public enum NewlineBehavior {
    /// Attach LF as the Unicode payload to a keycode-zero event (best-effort text insertion).
    case newline
    /// Send the Return/Enter keycode (may submit in chat fields).
    case enter
    /// Ignore newline characters.
    case omit
}

/// Progressively sends text to the currently focused macOS application.
///
/// Calls are serialized on a private queue, so callers can submit speech results
/// without blocking a UI or recognition thread. `append` means append-only text;
/// it does not revise text already delivered to the destination.
public final class TypingEngine {
    private let queue = DispatchQueue(label: "TypingCore.events", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let interCharacterDelay: TimeInterval
    private let emitter = KeyboardEmitter()
    private let newlineBehavior: NewlineBehavior

    /// - Parameter interCharacterDelay: Minimum delay between grapheme clusters.
    ///   Zero minimizes latency; a small positive value can help applications that
    ///   drop bursts. This is pacing for compatibility, not human simulation.
    public init(interCharacterDelay: TimeInterval = 0.005,
                newlineBehavior: NewlineBehavior) {
        self.interCharacterDelay = max(0, interCharacterDelay)
        self.newlineBehavior = newlineBehavior
    }

    /// Queue a complete string. Completion is called on the main queue after all
    /// events were posted, or with an error if permission/event creation failed.
    /// Posting success does not prove the destination accepted the text.
    public func type(_ text: String, completion: ((Result<Void, TypingError>) -> Void)? = nil) {
        enqueue(text, completion: completion)
    }

    /// Queue an append-only transcript chunk. Chunks are emitted in call order.
    public func append(_ text: String, completion: ((Result<Void, TypingError>) -> Void)? = nil) {
        enqueue(text, completion: completion)
    }

    /// Cancel queued/current work. Cancellation takes effect between grapheme
    /// clusters, after any key pair already in progress has been released.
    public func stop() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func enqueue(_ text: String, completion: ((Result<Void, TypingError>) -> Void)?) {
        lock.lock()
        let ticket = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, TypingError>
            if !CGPreflightPostEventAccess() {
                result = .failure(.postEventPermissionRequired)
            } else {
                do {
                    try TextEncoder.forEachAction(in: text, newlineBehavior: self.newlineBehavior) { action in
                        self.lock.lock()
                        let isCurrent = self.generation == ticket
                        self.lock.unlock()
                        guard isCurrent else { throw TypingError.cancelled }
                        try self.emitter.emit(action)
                        if self.interCharacterDelay > 0 {
                            Thread.sleep(forTimeInterval: self.interCharacterDelay)
                        }
                    }
                    result = .success(())
                } catch let error as TypingError {
                    result = .failure(error)
                } catch {
                    result = .failure(.cannotCreateEvent)
                }
            }
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
        // Keep the lock through queue submission so concurrent callers are ordered
        // consistently with the generation snapshot and stop() boundary.
        lock.unlock()
    }
}
