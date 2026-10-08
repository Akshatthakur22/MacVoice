import CoreGraphics
import Foundation

/// How newline characters are delivered. CGEvent has no universal newline
/// operation: apps may treat either Unicode LF or Return as a submit command.
public enum NewlineBehavior: Equatable {
    /// Send original CR/LF scalar payloads on keycode-zero events (best-effort text insertion).
    case newline
    /// Send the Return/Enter keycode (may submit in chat fields).
    case enter
    /// Send Shift+Return (commonly inserts a line break in chat fields).
    case shiftEnter
    /// Ignore newline characters.
    case omit
}

/// A completed batch's event count. This confirms submission to the Quartz event
/// stream only; CGEvent does not report whether the destination inserted the text.
public struct TypingReport {
    public let eventPairsPosted: Int
    /// Time from enqueue() until the first pair's post() calls returned. Nil for
    /// empty text. This is not target-app receipt latency.
    public let timeToFirstEvent: TimeInterval?
}

private enum TypingControl: Error { case cancelled }

/// Progressively sends text to the currently focused macOS application.
///
/// Calls are serialized on a private queue, so callers can submit speech results
/// without blocking a UI or recognition thread. `append` means append-only text;
/// it does not revise text already delivered to the destination.
public final class TypingEngine {
    /// Gives apps time to process text on either side of a Shift+Return boundary.
    private let shiftEnterSettleDelay: TimeInterval = 0.025
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

    /// Queue a complete string. Completion reports how many event pairs were
    /// submitted to Quartz. It cannot confirm target-app insertion.
    public func type(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)? = nil) {
        enqueue(text, completion: completion)
    }

    /// Queue an append-only transcript chunk. Chunks are emitted in call order.
    public func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)? = nil) {
        enqueue(text, completion: completion)
    }

    /// Cancel queued/current work. Cancellation takes effect between grapheme
    /// clusters, after any key pair already in progress has been released.
    public func stop() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func enqueue(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {
        lock.lock()
        let ticket = generation
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            guard let self else { return }
            if text.isEmpty {
                if let completion {
                    DispatchQueue.main.async { completion(.success(TypingReport(eventPairsPosted: 0, timeToFirstEvent: nil))) }
                }
                return
            }
            let result: Result<TypingReport, TypingError>
            if !CGPreflightPostEventAccess() {
                result = .failure(.postEventPermissionRequired)
            } else {
                var posted = 0
                var firstEventLatency: TimeInterval?
                do {
                    try TextEncoder.forEachAction(in: text, newlineBehavior: self.newlineBehavior) { action in
                        let isShiftEnter: Bool
                        if case .shiftEnter = action {
                            isShiftEnter = true
                            // Let preceding text reach apps whose editor handles
                            // Shift+Return on a separate input path.
                            Thread.sleep(forTimeInterval: max(self.shiftEnterSettleDelay, self.interCharacterDelay))
                        } else {
                            isShiftEnter = false
                        }
                        self.lock.lock()
                        let isCurrent = self.generation == ticket
                        self.lock.unlock()
                        guard isCurrent else { throw TypingControl.cancelled }
                        try self.emitter.emit(action)
                        posted += 1
                        if firstEventLatency == nil {
                            firstEventLatency = Double(DispatchTime.now().uptimeNanoseconds &- enqueuedAt) / 1_000_000_000
                        }
                        let pacingDelay = isShiftEnter
                            ? max(self.shiftEnterSettleDelay, self.interCharacterDelay)
                            : self.interCharacterDelay
                        if pacingDelay > 0 {
                            Thread.sleep(forTimeInterval: pacingDelay)
                        }
                    }
                    result = .success(TypingReport(eventPairsPosted: posted, timeToFirstEvent: firstEventLatency))
                } catch is TypingControl {
                    result = .failure(.cancelled(eventPairsPosted: posted))
                } catch let error as TypingError {
                    if case .eventCreationFailed = error {
                        result = .failure(.eventCreationFailed(eventPairsPosted: posted))
                    } else {
                        result = .failure(error)
                    }
                } catch {
                    result = .failure(.eventCreationFailed(eventPairsPosted: posted))
                }
            }
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
        // Keep the lock through queue submission so concurrent callers are ordered
        // consistently with the generation snapshot and stop() boundary.
        lock.unlock()
    }
}
