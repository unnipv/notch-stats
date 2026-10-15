import Foundation

/// Runs `work` and returns `fallback` if it does not finish within `seconds`.
///
/// Used to fence off calls that can block on user interaction — notably reading
/// another app's keychain item, which macOS gates behind an approval prompt.
/// Without this, one unapproved provider would stall the entire refresh.
func withTimeout<T: Sendable>(seconds: Double,
                              fallback: @autoclosure @escaping @Sendable () -> T,
                              work: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? fallback()
    }
}
