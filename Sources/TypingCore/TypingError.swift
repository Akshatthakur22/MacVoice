import Foundation

public enum TypingError: Error, LocalizedError {
    case postEventPermissionRequired
    case eventCreationFailed(eventPairsPosted: Int)
    case cancelled(eventPairsPosted: Int)

    public var errorDescription: String? {
        switch self {
        case .postEventPermissionRequired:
            return "Allow this app to control your Mac in Privacy & Security > Accessibility."
        case .eventCreationFailed(let count):
            return "macOS could not create the next keyboard event (\(count) event pairs were posted before the failure)."
        case .cancelled(let count):
            return "Typing was cancelled after posting \(count) event pairs."
        }
    }
}
