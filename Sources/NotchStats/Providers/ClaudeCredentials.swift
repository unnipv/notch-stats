import Foundation
import Security

/// Finds the credential Claude Code already wrote, without ever modifying it
/// and — unless the user opted in — without ever being able to make macOS ask
/// for a password.
///
/// Sources, tried in order:
/// 1. the `CLAUDE_CODE_OAUTH_TOKEN` environment variable,
/// 2. `~/.claude/.credentials.json` — a plain file, no keychain involved,
/// 3. the login keychain, **only** when "Allow Keychain Access" is on.
///
/// With the opt-in off the keychain is only ever *probed* for the existence of
/// an item (attributes, never the secret), and that probe is configured to
/// fail instead of showing a dialog. Every keychain call that can return the
/// secret also fails rather than prompts, except the single one the user
/// triggers by turning the opt-in on (`requestKeychainAccess`).
///
/// Two kinds of credential turn up in practice and they behave differently: an
/// **OAuth token** (`sk-ant-oat…`, Pro/Max login) can report usage limits, while
/// an **API key** (`sk-ant-api…`) belongs to an API organisation, where
/// Anthropic reports that usage limits do not apply.
///
/// Strictly read-only: nothing here writes, refreshes or deletes a credential.
enum ClaudeCredentials {
    enum Kind {
        case oauth
        case apiKey

        init(token: String) {
            self = token.contains("-oat") ? .oauth : .apiKey
        }
    }

    struct Credential: Equatable {
        let token: String
        let kind: Kind
        let expiresAt: Date?

        func isExpired(now: Date = Date()) -> Bool {
            guard kind == .oauth, let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    enum Source: String {
        case environment = "environment"
        case file = "credentials file"
        case keychain = "keychain"
        /// The last good credential, kept briefly while the file is missing or
        /// being rewritten.
        case lastKnown = "last known"
    }

    /// Why nothing was found. Kept apart so a *failed read* is never reported
    /// as a *missing login*.
    enum Failure: Equatable {
        /// Every place we may look answered "nothing here".
        case notSignedIn
        /// The keychain holds a Claude login, but the opt-in is off.
        case keychainNotAllowed
        /// The keychain is locked or refused a read we were allowed to try.
        case keychainDenied
        /// The credentials file is there but cannot be read yet — usually the
        /// CLI is rewriting it.
        case fileUnreadable

        var issue: ProviderIssue {
            switch self {
            case .notSignedIn: return .notSignedIn
            case .keychainNotAllowed: return .keychainNotAllowed
            case .keychainDenied: return .keychainDenied
            case .fileUnreadable: return .unreadable
            }
        }
    }

    enum Resolution: Equatable {
        case found(Credential, Source)
        case missing(Failure)
    }

    // MARK: - Seam

    enum FileRead: Equatable {
        case absent
        case unreadable
        case data(Data)
    }

    /// Answer to "is there a Claude item in the keychain?" — attributes only.
    enum KeychainProbe: Equatable {
        case present
        case absent
        /// Locked, or the call failed: we can't tell.
        case unknown
    }

    /// Answer to a secret read that was not allowed to prompt.
    enum KeychainSecret: Equatable {
        case found(Data)
        case absent
        /// The item exists (or the keychain is locked) and we may not read it.
        case refused
    }

    /// Everything resolution consults, so the order is testable without
    /// touching the real keychain or the real home directory.
    struct Inputs {
        var environment: [String: String]
        var readFile: () -> FileRead
        var keychainAllowed: Bool
        var probeKeychain: () -> KeychainProbe
        var readKeychain: () -> KeychainSecret

        static func live(keychainAllowed: Bool) -> Inputs {
            Inputs(environment: ProcessInfo.processInfo.environment,
                   readFile: Keychain.liveFileRead,
                   keychainAllowed: keychainAllowed,
                   probeKeychain: { Keychain.probe() },
                   readKeychain: { Keychain.readSecret(interaction: .fail) })
        }
    }

    struct LastGood: Equatable {
        let credential: Credential
        let source: Source
        let at: Date
    }

    /// How long a good credential outlives a missing or half-written file.
    static let graceLifetime: TimeInterval = 120

    /// Pure resolution. The keychain is not consulted unless `keychainAllowed`
    /// — apart from the attribute-only probe that makes a missing login and an
    /// unreadable one look different.
    static func resolve(_ inputs: Inputs, lastGood: LastGood?, now: Date = Date()) -> Resolution {
        if let raw = inputs.environment["CLAUDE_CODE_OAUTH_TOKEN"] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return .found(Credential(token: token, kind: .init(token: token), expiresAt: nil), .environment)
            }
        }

        var fileProblem = false
        switch inputs.readFile() {
        case .absent:
            break
        case .unreadable:
            fileProblem = true
        case let .data(data):
            if let credential = credential(from: data) { return .found(credential, .file) }
            // Present but not parseable: the CLI writes it non-atomically.
            fileProblem = true
        }

        var keychain: Failure?
        if inputs.keychainAllowed {
            switch inputs.readKeychain() {
            case let .found(data):
                if let credential = credential(from: data) { return .found(credential, .keychain) }
                keychain = .keychainDenied
            case .absent:
                break
            case .refused:
                keychain = .keychainDenied
            }
        } else {
            switch inputs.probeKeychain() {
            case .present: keychain = .keychainNotAllowed
            case .unknown: keychain = .keychainDenied
            case .absent: break
            }
        }

        // A file that is missing or mid-rewrite must not wipe a token that was
        // good a moment ago; the next tick reads it again.
        if let lastGood, now.timeIntervalSince(lastGood.at) < graceLifetime,
           !lastGood.credential.isExpired(now: now) {
            return .found(lastGood.credential, .lastKnown)
        }

        if let keychain { return .missing(keychain) }
        return .missing(fileProblem ? .fileUnreadable : .notSignedIn)
    }

    // MARK: - State

    /// UserDefaults key behind the "Allow Keychain Access" menu item. Off by
    /// default.
    static let keychainOptInKey = "allowKeychainAccess"

    static var keychainAllowed: Bool {
        UserDefaults.standard.bool(forKey: keychainOptInKey)
    }

    private static let lastGood = Locked<LastGood?>(nil)

    /// Forgets the remembered credential (after a 401, a wake, or a manual
    /// refresh), so the next resolve reads the sources again.
    static func invalidate() { lastGood.withLock { $0 = nil } }

    private static let queue = DispatchQueue(label: "dev.notchstats.claude.credentials", qos: .utility)

    static func resolveAsync(force: Bool = false) async -> Resolution {
        if force { invalidate() }
        let inputs = Inputs.live(keychainAllowed: keychainAllowed)
        let previous = lastGood.withLock { $0 }
        let resolution = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: resolve(inputs, lastGood: previous)) }
        }
        if case let .found(credential, source) = resolution, source != .lastKnown {
            lastGood.withLock { $0 = LastGood(credential: credential, source: source, at: Date()) }
        }
        return resolution
    }

    /// The one place that may show a macOS password dialog: run when the user
    /// turns "Allow Keychain Access" on. Background reads never prompt, so if
    /// the user answers "Allow" rather than "Always Allow" the credential is
    /// kept for a short while and then shows the "not readable" caption.
    static func requestKeychainAccess() async {
        let secret = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Keychain.readSecret(interaction: .allow)) }
        }
        if case let .found(data) = secret, let credential = credential(from: data) {
            lastGood.withLock { $0 = LastGood(credential: credential, source: .keychain, at: Date()) }
        }
    }

    // MARK: - Keychain and file access

    private enum Keychain {
        /// Claude Code stores its login under both of these services.
        static let services = ["Claude Code-credentials", "Claude Code"]

        enum Interaction { case fail, allow }

        static func liveFileRead() -> FileRead {
            let path = NSHomeDirectory() + "/.claude/.credentials.json"
            guard FileManager.default.fileExists(atPath: path) else { return .absent }
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return .unreadable }
            return .data(data)
        }

        /// Attributes only — no secret is requested, so this can never ask
        /// for a password. `UIFail` also stops a locked keychain from showing
        /// an unlock dialog.
        static func probe() -> KeychainProbe {
            var unknown = false
            for service in services {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
                ]
                var item: CFTypeRef?
                switch SecItemCopyMatching(query as CFDictionary, &item) {
                case errSecSuccess: return .present
                case errSecItemNotFound: continue
                default: unknown = true
                }
            }
            return unknown ? .unknown : .absent
        }

        /// Reads the secret. With `.fail` (every background read) macOS gets
        /// no chance to prompt; `.allow` is only used for the user's one-off
        /// grant.
        static func readSecret(interaction: Interaction) -> KeychainSecret {
            var refused = false
            for service in services {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                // Without the key macOS may prompt — that is `.allow`.
                if interaction == .fail {
                    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
                }
                var item: CFTypeRef?
                switch SecItemCopyMatching(query as CFDictionary, &item) {
                case errSecSuccess:
                    if let data = item as? Data { return .found(data) }
                case errSecItemNotFound:
                    continue
                default:
                    refused = true
                }
            }
            return refused ? .refused : .absent
        }
    }

    // MARK: - Parsing

    static func credential(from data: Data) -> Credential? {
        if let object = jsonObject(data) {
            // macOS keychain shape: { "claudeAiOauth": { "accessToken": … } }
            // Some files are flat:  { "accessToken": … }
            let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
            guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
            return Credential(token: token, kind: .init(token: token), expiresAt: expiry(oauth["expiresAt"]))
        }

        // The "Claude Code" item holds a bare API key rather than JSON.
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("sk-ant-") {
            return Credential(token: raw, kind: .init(token: raw), expiresAt: nil)
        }
        return nil
    }

    private static func expiry(_ value: Any?) -> Date? {
        guard let value = asDouble(value) else { return nil }
        // Stored as milliseconds since the epoch; tolerate seconds too.
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }
}

/// Minimal lock-protected box.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
