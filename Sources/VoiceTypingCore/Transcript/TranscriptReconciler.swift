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
        if update.isFinal || update.endsSegment {
            safeText = confirmed
        } else {
            safeText = String(confirmed.dropLast())
        }
        let safeBytes = Array(safeText.utf8)
        // After a segment end released the last grapheme, the next update
        // withholds it again; that text is already typed, so nothing is new.
        // (Both are prefixes of the confirmed text, so one extends the other.)
        if emittedUTF8.starts(with: safeBytes) { return "" }
        guard safeBytes.starts(with: emittedUTF8) else {
            throw TranscriptReconciliationError.confirmedTextWasRevised
        }
        let delta = String(decoding: safeBytes.dropFirst(emittedUTF8.count), as: UTF8.self)
        emittedUTF8 = safeBytes
        return delta
    }

    /// Recovers from a revision without ending dictation: adopts `update` as
    /// the new baseline, so later text continues from it. Text that was
    /// revised is not retyped (keystrokes are append-only).
    public mutating func resynchronize(to update: SpeechRecognitionUpdate) {
        confirmedUTF8 = Array(update.confirmedTranscript.utf8)
        let safeText = update.isFinal || update.endsSegment
            ? update.confirmedTranscript
            : String(update.confirmedTranscript.dropLast())
        let safeBytes = Array(safeText.utf8)
        // If more was typed than the revised text holds, skip all of it so
        // nothing is typed twice.
        emittedUTF8 = safeBytes.count >= emittedUTF8.count ? safeBytes : confirmedUTF8
    }

    /// Reset after a recognition session ends.
    public mutating func reset() {
        confirmedUTF8.removeAll(keepingCapacity: false)
        emittedUTF8.removeAll(keepingCapacity: false)
    }
}
