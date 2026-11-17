import AppKit
import ApplicationServices
import Carbon
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
    /// Intelligently sends Shift+Return when frontmost app is a chat app (Slack, WhatsApp, Discord, etc.),
    /// or standard newline in text editors/IDEs.
    case smartChatAware
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

/// Append-only output boundary used by VoiceTypingSession. `drain()` waits until
/// previously submitted Quartz work has completed; it does not confirm that a
/// destination application inserted the posted events.
public protocol TypingOutput: AnyObject {
    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?)
    func stop()
    func drain() async
    /// Marks the start of a new dictation and reports what is known about the
    /// destination (frontmost app, text before the caret). Default: unknown.
    func beginDictation() async -> InsertionContext
    /// Removes the text of the most recent `append` with Backspace, if this
    /// dictation typed it. Used by the spoken "scratch that" command.
    func retractLastAppend()
}

public extension TypingOutput {
    func beginDictation() async -> InsertionContext { .unknown }
    func retractLastAppend() {}
}

private enum TypingControl: Error { case cancelled }

/// Progressively sends text to the currently focused macOS application.
///
/// Calls are serialized on a private queue, so callers can submit speech results
/// without blocking a UI or recognition thread. `append` means append-only text;
/// it does not revise text already delivered to the destination.
/// Thread safety: mutable state is confined to `queue` or guarded by `lock`.
public final class TypingEngine: TypingOutput, @unchecked Sendable {
    /// Gives apps time to process text on either side of a Shift+Return boundary.
    private let shiftEnterSettleDelay: TimeInterval = 0.025
    private let queue = DispatchQueue(label: "TypingCore.events", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let interCharacterDelay: TimeInterval
    private let emitter = KeyboardEmitter()
    private let newlineBehavior: NewlineBehavior
    private let smartLeadingSpace: Bool
    // Typing-queue-confined state for spacing and "scratch that".
    private var spacingContext: InsertionContext.Preceding?
    private var tail: InsertionContext.Preceding = .unknown
    private var tailBeforeLastAppend: InsertionContext.Preceding = .unknown
    private var lastAppendKeyCount = 0

    /// - Parameter interCharacterDelay: Minimum delay between grapheme clusters.
    ///   Zero minimizes latency; a small positive value can help applications that
    ///   drop bursts. This is pacing for compatibility, not human simulation.
    /// - Parameter smartLeadingSpace: When true, the first text of each
    ///   dictation gets a leading space if the character before the caret is
    ///   not already whitespace (so "done." + "Next" becomes "done. Next").
    public init(interCharacterDelay: TimeInterval = 0.005,
                newlineBehavior: NewlineBehavior,
                smartLeadingSpace: Bool = false) {
        self.interCharacterDelay = max(0, interCharacterDelay)
        self.newlineBehavior = newlineBehavior
        self.smartLeadingSpace = smartLeadingSpace
    }

    public func beginDictation() async -> InsertionContext {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let context = FocusedTextContext.current()
                tail = context.preceding
                tailBeforeLastAppend = context.preceding
                lastAppendKeyCount = 0
                spacingContext = smartLeadingSpace ? context.preceding : nil
                continuation.resume(returning: context)
            }
        }
    }

    public func retractLastAppend() {
        lock.lock()
        let ticket = generation
        queue.async { [weak self] in
            guard let self else { return }
            let count = self.lastAppendKeyCount
            guard count > 0, CGPreflightPostEventAccess(), !IsSecureEventInputEnabled() else { return }
            for _ in 0..<count {
                self.lock.lock()
                let isCurrent = self.generation == ticket
                self.lock.unlock()
                guard isCurrent else { return }
                try? self.emitter.emit(.keyCode(51)) // Delete (Backspace)
                if self.interCharacterDelay > 0 { Thread.sleep(forTimeInterval: self.interCharacterDelay) }
            }
            self.lastAppendKeyCount = 0
            self.tail = self.tailBeforeLastAppend
            // Re-check spacing for the next text against what is now before the caret.
            if self.smartLeadingSpace { self.spacingContext = self.tail }
        }
        lock.unlock()
    }

    private var effectiveNewlineBehavior: NewlineBehavior {
        switch newlineBehavior {
        case .smartChatAware:
            return Self.isFrontmostAppChat ? .shiftEnter : .enter
        case .newline:
            return .enter
        default:
            return newlineBehavior
        }
    }

    public static var isFrontmostAppChat: Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = frontmost.bundleIdentifier?.lowercased() ?? ""
        let chatBundleIdentifiers: Set<String> = [
            "net.whatsapp.whatsapp",
            "com.tinyspeck.slackmacgap",
            "com.hnc.discord",
            "ru.keepcoder.telegram",
            "com.tdesktop.telegram",
            "com.apple.mobilesms",
            "com.facebook.archon",
            "org.whispersystems.signal-desktop",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.skype.skype",
            "im.riot.app"
        ]
        if chatBundleIdentifiers.contains(bundleID) { return true }
        let chatKeywords = ["slack", "whatsapp", "discord", "telegram", "messenger", "signal", "teams"]
        if chatKeywords.contains(where: { bundleID.contains($0) }) { return true }

        // Web chat detection (Slack, WhatsApp Web…) only applies inside browsers;
        // elsewhere a title like "slack_bot.py" must not change newline behavior.
        let browserBundleIdentifiers: Set<String> = [
            "com.apple.safari", "com.google.chrome", "com.google.chrome.canary", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser", "com.operasoftware.opera",
            "com.vivaldi.vivaldi", "app.zen-browser.zen", "com.kagi.kagimacos"
        ]
        guard browserBundleIdentifiers.contains(bundleID) else { return false }
        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        var windowValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let window = windowValue {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                let lowerTitle = title.lowercased()
                if chatKeywords.contains(where: { lowerTitle.contains($0) }) {
                    return true
                }
            }
        }
        return false
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

    /// Waits for all event batches submitted before this call to finish.
    /// Completion means Quartz processing returned, not that a target app inserted text.
    public func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
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
            var text = text
            if let context = self.spacingContext {
                self.spacingContext = nil
                text = FocusedTextContext.adjustLeadingSpacing(text, after: context)
                guard !text.isEmpty else {
                    if let completion {
                        DispatchQueue.main.async { completion(.success(TypingReport(eventPairsPosted: 0, timeToFirstEvent: nil))) }
                    }
                    return
                }
            }
            let result: Result<TypingReport, TypingError>
            if !CGPreflightPostEventAccess() {
                result = .failure(.postEventPermissionRequired)
            } else if IsSecureEventInputEnabled() {
                result = .failure(.secureInputActive)
            } else {
                var posted = 0
                var firstEventLatency: TimeInterval?
                do {
                    try TextEncoder.forEachAction(in: text, newlineBehavior: self.effectiveNewlineBehavior) { action in
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
                    self.tailBeforeLastAppend = self.tail
                    self.lastAppendKeyCount = posted
                    if let last = text.last { self.tail = .text(String(last)) }
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
            if case .failure = result {
                // Unknown how much reached the app; never retract a partial batch.
                self.lastAppendKeyCount = 0
                self.tail = .unknown
            }
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
        // Keep the lock through queue submission so concurrent callers are ordered
        // consistently with the generation snapshot and stop() boundary.
        lock.unlock()
    }
}
