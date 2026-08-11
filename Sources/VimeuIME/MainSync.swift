import Foundation

/// Run `work` on the main actor and wait for its result.
///
/// IMKit predates Swift Concurrency: `IMKInputController`'s methods are imported
/// as nonisolated, so the controller cannot be MainActor-isolated (an override
/// may not add isolation). In practice IMK always calls them on the main thread,
/// which makes `assumeIsolated` correct there and free.
///
/// The `Thread.isMainThread` check matters: a plain `DispatchQueue.main.sync`
/// from the main thread deadlocks, and IMK reentrancy makes that easy to hit.
@discardableResult
func mainSync<T: Sendable>(_ work: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(work)
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
}
