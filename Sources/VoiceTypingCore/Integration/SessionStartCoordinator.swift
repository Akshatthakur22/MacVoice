import Foundation

/// Owns the host's asynchronous start operation so duplicate activations are
/// rejected and cancellation can be awaited before another start is accepted.
@MainActor
public final class SessionStartCoordinator {
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {}

    public var isRunning: Bool { operation != nil }

    /// Starts the production operation once. Errors are returned to the caller's
    /// handler; cancellation is quiet and releases the gate when the operation exits.
    @discardableResult
    public func begin(
        operation start: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Bool {
        guard operation == nil else { return false }
        generation &+= 1
        let ticket = generation
        operation = Task { @MainActor [weak self] in
            defer { self?.finish(ticket) }
            do {
                try await start()
            } catch is CancellationError {
                // Cancellation is an expected control flow for teardown.
            } catch {
                onFailure(error)
            }
        }
        return true
    }

    public func cancelAndWait() async {
        guard let current = operation else { return }
        current.cancel()
        await current.value
    }

    public func waitForCurrentOperation() async {
        let current = operation
        await current?.value
    }

    private func finish(_ ticket: UInt64) {
        guard ticket == generation else { return }
        operation = nil
    }
}
