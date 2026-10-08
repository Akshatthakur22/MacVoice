import Foundation

public enum TranscriptReconciliationError: Error, Equatable {
    case confirmedTextWasRevised
}

/// Converts a recognizer's cumulative confirmed transcript into append-only
/// grapheme-safe deltas. Provisional hypotheses are intentionally ignored.
public struct TranscriptReconciler {
    private var confirmedUTF8: [UInt8] = []
    private var emittedUTF8: [UInt8] = []

    public init() {}

    /// Returns newly committed text, withholding its final grapheme until a
    /// later update or finalization so a combining scalar cannot be split
    /// across TypingCore.append calls.
    public mutating func consume(_ update: SpeechRecognitionUpdate) throws -> String {
        let bytes = Array(update.confirmedTranscript.utf8)
        guard bytes.starts(with: confirmedUTF8) else {
            throw TranscriptReconciliationError.confirmedTextWasRevised
        }
        confirmedUTF8 = bytes

        let confirmed = update.confirmedTranscript
        let safeText: String
        if update.isFinal {
            safeText = confirmed
        } else {
            safeText = String(confirmed.dropLast())
        }
        let safeBytes = Array(safeText.utf8)
        guard safeBytes.starts(with: emittedUTF8) else {
            throw TranscriptReconciliationError.confirmedTextWasRevised
        }
        let delta = String(decoding: safeBytes.dropFirst(emittedUTF8.count), as: UTF8.self)
        emittedUTF8 = safeBytes
        return delta
    }

    /// Reset after a recognition session ends.
    public mutating func reset() {
        confirmedUTF8.removeAll(keepingCapacity: false)
        emittedUTF8.removeAll(keepingCapacity: false)
    }
}
