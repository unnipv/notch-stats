import Foundation
import LocalAuthentication
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
            let env = ProcessInfo.processInfo.environment
            return Inputs(environment: env,
                          readFile: { Keychain.liveFileRead(environment: env) },
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

    /// Outcome of parsing raw credential bytes from disk or the keychain.
    /// Kept separate from `Credential?` so an explicitly cleared login
    /// (`{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}`)
    /// is never mistaken for a half-written file or a denied keychain read.
    enum ParseResult: Equatable {
        case credential(Credential)
        /// Valid JSON whose `claudeAiOauth` object explicitly has an empty token
        /// (the shape Claude Code writes when clearing a dead/signed-out grant).
        case cleared
        /// Unparseable, truncated, or unrecognised bytes.
        case malformed
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
        var fileCleared = false
        var expiredFileCredential: Credential?
        switch inputs.readFile() {
        case .absent:
            break
        case .unreadable:
            fileProblem = true
        case let .data(data):
            switch parseCredential(from: data) {
            case let .credential(credential):
                if !credential.isExpired(now: now) {
                    return .found(credential, .file)
                }
                // File token is expired. If the keychain is opted in, check
                // whether a fresher token lives there before declaring expiry.
                expiredFileCredential = credential
            case .cleared:
                fileCleared = true
            case .malformed:
                // Present but not parseable: the CLI writes it non-atomically.
                fileProblem = true
            }
        }

        var keychain: Failure?
        var keychainCleared = false
        var expiredKeychainCredential: Credential?
        if inputs.keychainAllowed {
            switch inputs.readKeychain() {
            case let .found(data):
                switch parseCredential(from: data) {
                case let .credential(credential):
                    if !credential.isExpired(now: now) {
                        return .found(credential, .keychain)
                    }
                    expiredKeychainCredential = credential
                case .cleared:
                    keychainCleared = true
                case .malformed:
                    keychain = .keychainDenied
                }
            case .absent:
                break
            case .refused:
                keychain = .keychainDenied
            }
        } else if expiredFileCredential == nil {
            switch inputs.probeKeychain() {
            case .present: keychain = .keychainNotAllowed
            case .unknown: keychain = .keychainDenied
            case .absent: break
            }
        }

        // No live (unexpired) token was found; if one or both sources had an
        // expired token, report the most recent one rather than "not signed in".
        if let chosen = fresherExpired(file: expiredFileCredential, keychain: expiredKeychainCredential) {
            return .found(chosen.credential, chosen.source)
        }

        // An explicit cleared login (empty accessToken in valid JSON) means the
        // CLI signed out; do not mask it behind a cached token from that store.
        let explicitlyCleared = keychainCleared || (fileCleared && (keychain == nil || lastGood?.source == .file))

        // A file that is missing or mid-rewrite must not wipe a token that was
        // good a moment ago; the next tick reads it again.
        if !explicitlyCleared,
           let lastGood, now.timeIntervalSince(lastGood.at) < graceLifetime,
           !lastGood.credential.isExpired(now: now) {
            return .found(lastGood.credential, .lastKnown)
        }

        if let keychain { return .missing(keychain) }
        return .missing(fileProblem ? .fileUnreadable : .notSignedIn)
    }

    private static func fresherExpired(file: Credential?, keychain: Credential?) -> (credential: Credential, source: Source)? {
        switch (file, keychain) {
        case let (.some(f), .some(k)):
            let fTime = f.expiresAt?.timeIntervalSince1970 ?? 0
            let kTime = k.expiresAt?.timeIntervalSince1970 ?? 0
            return kTime > fTime ? (k, .keychain) : (f, .file)
        case let (.some(f), .none):
            return (f, .file)
        case let (.none, .some(k)):
            return (k, .keychain)
        case (.none, .none):
            return nil
        }
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
        if case let .found(credential, source) = resolution,
           source != .lastKnown, !credential.isExpired() {
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

    enum Keychain {
        /// Claude Code stores its login under both of these services.
        static let services = ["Claude Code-credentials", "Claude Code"]

        enum Interaction { case fail, allow }

        /// Resolves the path to Claude Code's credentials file, honouring
        /// `CLAUDE_CONFIG_DIR` when set and falling back to `~/.claude`.
        /// Never reads or creates lock files (`.credentials.lock`,
        /// `.oauth_refresh.lock`).
        static func credentialsFilePath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        homeDirectory: String = NSHomeDirectory()) -> String {
            let override = environment["CLAUDE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base: String
            if !override.isEmpty {
                base = (override as NSString).expandingTildeInPath
            } else {
                base = (homeDirectory as NSString).appendingPathComponent(".claude")
            }
            return (base as NSString).appendingPathComponent(".credentials.json")
        }

        static func liveFileRead(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 homeDirectory: String = NSHomeDirectory()) -> FileRead {
            let path = credentialsFilePath(environment: environment, homeDirectory: homeDirectory)
            guard FileManager.default.fileExists(atPath: path) else { return .absent }
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return .unreadable }
            return .data(data)
        }

        /// Builds the attributes-only existence query. Never sets
        /// `kSecReturnData` and attaches a non-interactive `LAContext` so
        /// macOS can never show a password or unlock dialog.
        static func probeQuery(service: String) -> [String: Any] {
            let context = LAContext()
            context.interactionNotAllowed = true
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]
        }

        /// Builds the secret-read query. `.fail` (every background read)
        /// attaches a non-interactive `LAContext`; `.allow` is only used for
        /// the user's one-off opt-in click.
        static func secretQuery(service: String, interaction: Interaction) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if interaction == .fail {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            return query
        }

        /// Attributes only — no secret is requested, so this can never ask
        /// for a password. `interactionNotAllowed` also stops a locked keychain
        /// from showing an unlock dialog.
        static func probe() -> KeychainProbe {
            var unknown = false
            for service in services {
                var item: CFTypeRef?
                switch SecItemCopyMatching(probeQuery(service: service) as CFDictionary, &item) {
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
                var item: CFTypeRef?
                switch SecItemCopyMatching(secretQuery(service: service, interaction: interaction) as CFDictionary, &item) {
                case errSecSuccess:
                    if let data = item as? Data { return .found(data) }
                    refused = true
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

    static func parseCredential(from data: Data) -> ParseResult {
        if let object = jsonObject(data) {
            // macOS keychain shape: { "claudeAiOauth": { "accessToken": … } }
            // Some files are flat:  { "accessToken": … }
            let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
            if let token = oauth["accessToken"] as? String {
                if !token.isEmpty {
                    return .credential(Credential(token: token, kind: .init(token: token),
                                                  expiresAt: expiry(oauth["expiresAt"])))
                }
                // Explicit empty accessToken inside valid JSON (Claude Code's
                // dead-token disk clear writes accessToken:"", refreshToken:"",
                // expiresAt:0).
                return .cleared
            }
            return .malformed
        }

        // The "Claude Code" item holds a bare API key rather than JSON.
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("sk-ant-") {
            return .credential(Credential(token: raw, kind: .init(token: raw), expiresAt: nil))
        }
        return .malformed
    }

    static func credential(from data: Data) -> Credential? {
        guard case let .credential(credential) = parseCredential(from: data) else { return nil }
        return credential
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
