import Foundation
import LocalAuthentication
import Security

/// Serializes macOS Keychain user-interaction policy around every
/// `SecItemCopyMatching` call so background operations can never display a
/// password or ACL prompt.
///
/// Why all three mechanisms are required on macOS:
/// 1. `SecKeychainSetUserInteractionAllowed(false)` — required by `securityd`'s
///    legacy file-based login-keychain (`login.keychain-db`) ACL evaluator
///    (`AclValidationContext(action:24)`). Without it, even queries setting
///    both `kSecUseAuthenticationUIFail` and `LAContext.interactionNotAllowed`
///    still raise a password dialog on legacy keychain items.
/// 2. `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` — suppresses
///    authentication UI on SecItem paths.
/// 3. `LAContext.interactionNotAllowed = true` (`kSecUseAuthenticationContext`)
///    — suppresses LocalAuthentication and Data Protection Keychain UI.
enum KeychainGuard {
    private static let lock = NSLock()

    /// Disables legacy Keychain user interaction process-wide. Called at app
    /// launch before any provider runs.
    static func disableBackgroundInteraction() {
        lock.lock()
        defer { lock.unlock() }
        _ = SecKeychainSetUserInteractionAllowed(false)
    }

    /// Executes a Keychain lookup under a serial lock with the requested
    /// legacy interaction policy, always restoring `false` before releasing
    /// the lock so a background call can never inherit `true`.
    static func withInteraction<T>(allowed: Bool, _ body: () -> T) -> T {
        lock.lock()
        defer {
            _ = SecKeychainSetUserInteractionAllowed(false)
            lock.unlock()
        }
        _ = SecKeychainSetUserInteractionAllowed(allowed)
        return body()
    }

    /// Reads the current legacy Keychain interaction setting (for tests).
    static var isLegacyInteractionAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        var state = DarwinBoolean(false)
        _ = SecKeychainGetUserInteractionAllowed(&state)
        return state.boolValue
    }

    /// Attaches both `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`
    /// and a non-interactive `LAContext` (`interactionNotAllowed = true`) to a
    /// `SecItemCopyMatching` query dictionary.
    static func applyNonInteractiveFlags(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        // UIFail (not LAContext alone) plus SecKeychainSetUserInteractionAllowed(false)
        // are required so securityd rejects missing ACL grants silently instead
        // of displaying a password prompt.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        query[kSecUseAuthenticationContext as String] = context
    }
}
