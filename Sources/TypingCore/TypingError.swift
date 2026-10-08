import Foundation

public enum TypingError: Error, LocalizedError {
    case postEventPermissionRequired
    case cannotCreateEvent
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .postEventPermissionRequired:
            return "Allow this app to control your Mac in Privacy & Security > Accessibility."
        case .cannotCreateEvent:
            return "macOS could not create a keyboard event."
        case .cancelled:
            return "Typing was cancelled."
        }
    }
}
