import Foundation
import LocalAuthentication
import Security

/// Finds the credential Claude Code already wrote, without ever modifying it
/// and without ever performing a Keychain secret read during background polls.
///
/// Sources, tried in order on every poll (zero `kSecReturnData` calls):
/// 1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable,
/// 2. `~/.claude/.credentials.json` (honouring `CLAUDE_CONFIG_DIR`) — plain file,
/// 3. App-private `0600` snapshot under
///    `~/Library/Application Support/NotchStats/credentials/claude.json`
///    (written only when the user clicks "Capture Claude login…"),
/// 4. In-memory session cache populated only once at launch (if "Allow Keychain
///    Access" is on) or by an explicit user action / wake-from-sleep.
///
/// Every non-interactive Keychain query sets **both**
/// `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` and an `LAContext`
/// with `interactionNotAllowed = true`. `UIFail` is what suppresses the legacy
/// login-keychain ACL dialog (`AclValidationContext(action:24)`); `LAContext`
/// alone does not.
///
/// Two kinds of credential turn up in practice and they behave differently: an
/// **OAuth token** (`sk-ant-oat…`, Pro/Max login) can report usage limits, while
/// an **API key** (`sk-ant-api…`) belongs to an API organisation, where
/// Anthropic reports that usage limits do not apply.
///
/// Strictly read-only on Claude Code's own files and Keychain items: nothing
/// here writes, refreshes, or deletes another app's credential.
enum ClaudeCredentials {
    enum Kind: Equatable, Sendable {
        case oauth
        case apiKey

        init(token: String) {
            self = token.contains("-oat") ? .oauth : .apiKey
        }
    }

    struct Credential: Equatable, Sendable {
        let token: String
        let kind: Kind
        let expiresAt: Date?

        func isExpired(now: Date = Date()) -> Bool {
            guard kind == .oauth, let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    enum Source: String, Equatable, Sendable {
        case environment = "environment"
        case file = "credentials file"
        case snapshot = "captured snapshot"
        case keychain = "keychain"
        /// The last good credential, kept briefly while the file is missing or
        /// being rewritten.
        case lastKnown = "last known"
    }

    /// Why nothing was found. Kept apart so a *failed read* is never reported
    /// as a *missing login*.
    enum Failure: Equatable, Sendable {
        /// Every place we may look answered "nothing here".
        case notSignedIn
        /// The keychain holds a Claude login, but it has not been captured/shared.
        case keychainNotAllowed
        /// The keychain is locked or refused a non-interactive read.
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

    enum Resolution: Equatable, Sendable {
        case found(Credential, Source)
        case missing(Failure)
    }

    // MARK: - Seam

    enum FileRead: Equatable, Sendable {
        case absent
        case unreadable
        case data(Data)
    }

    /// Answer to "is there a Claude item in the keychain?" — attributes only.
    enum KeychainProbe: Equatable, Sendable {
        case present
        case absent
        /// Locked, or the call failed: we can't tell.
        case unknown
    }

    /// Answer to a secret read from the keychain.
    enum KeychainSecret: Equatable, Sendable {
        case found(Data)
        case absent
        /// The item exists (or the keychain is locked) and we may not read it.
        case refused
    }

    /// Cached outcome of the process's one-off keychain read (launch, wake, or
    /// explicit capture). Passed as a plain value into `resolve(_:)` so the
    /// background poll path can never invoke `SecItemCopyMatching` with
    /// `kSecReturnData`.
    enum KeychainSessionState: Equatable, Sendable {
        case unattempted
        case credential(Credential)
        case cleared
        case malformed
        case absent
        case refused
    }

    enum CaptureResult: Equatable, Sendable {
        case captured(Credential)
        case absent
        case cleared
        case refused
        case malformed
        case writeFailed
    }

    /// Everything background resolution consults. Deliberately carries NO
    /// secret-reading closure: background polling performs zero keychain reads.
    struct Inputs {
        var environment: [String: String]
        var readFile: () -> FileRead
        var readSnapshot: () -> CredentialSnapshotStore.ReadResult
        var keychainAllowed: Bool
        var sessionKeychain: KeychainSessionState
        var probeKeychain: () -> KeychainProbe

        static func live(keychainAllowed: Bool,
                         sessionKeychain: KeychainSessionState,
                         snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory()) -> Inputs {
            let env = ProcessInfo.processInfo.environment
            return Inputs(environment: env,
                          readFile: { Keychain.liveFileRead(environment: env) },
                          readSnapshot: { CredentialSnapshotStore.read(provider: .claude, directory: snapshotDirectory) },
                          keychainAllowed: keychainAllowed,
                          sessionKeychain: sessionKeychain,
                          probeKeychain: { Keychain.probe() })
        }
    }

    struct LastGood: Equatable, Sendable {
        let credential: Credential
        let source: Source
        let at: Date
    }

    /// Outcome of parsing raw credential bytes from disk or the keychain.
    /// Kept separate from `Credential?` so an explicitly cleared login
    /// (`{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}`)
    /// is never mistaken for a half-written file or a denied keychain read.
    enum ParseResult: Equatable, Sendable {
        case credential(Credential)
        /// Valid JSON whose `claudeAiOauth` object explicitly has an empty token
        /// (the shape Claude Code writes when clearing a dead/signed-out grant).
        case cleared
        /// Unparseable, truncated, or unrecognised bytes.
        case malformed
    }

    /// How long a good credential outlives a missing or half-written file.
    static let graceLifetime: TimeInterval = 120

    /// Pure resolution. Never performs a Keychain secret read (`kSecReturnData`).
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
                // File token is expired. Check snapshot or cached keychain
                // token before declaring expiry.
                expiredFileCredential = credential
            case .cleared:
                fileCleared = true
            case .malformed:
                // Present but not parseable: the CLI writes it non-atomically.
                fileProblem = true
            }
        }

        // App-private 0600 snapshot captured explicitly by the user.
        if case let .valid(snapshot) = inputs.readSnapshot() {
            let credential = Credential(token: snapshot.accessToken,
                                        kind: .init(token: snapshot.accessToken),
                                        expiresAt: snapshot.expiresAtDate)
            if !credential.isExpired(now: now) {
                return .found(credential, .snapshot)
            }
        }

        // Consult the in-memory session keychain cache (populated once at
        // launch/wake when opted in, or via explicit Capture) — never reads
        // keychain secret bytes on poll ticks.
        var keychain: Failure?
        var keychainCleared = false
        var expiredKeychainCredential: Credential?
        switch inputs.sessionKeychain {
        case let .credential(credential):
            if !credential.isExpired(now: now) {
                return .found(credential, .keychain)
            }
            expiredKeychainCredential = credential
        case .cleared:
            keychainCleared = true
        case .malformed, .refused:
            keychain = .keychainDenied
        case .absent:
            break
        case .unattempted:
            switch inputs.probeKeychain() {
            case .present: keychain = .keychainNotAllowed
            case .unknown: keychain = .keychainDenied
            case .absent: break
            }
        }

        // If no unshared/denied keychain login is waiting to be shared and at
        // least one source had an expired token, surface the fresher expiry.
        if keychain == nil,
           let chosen = fresherExpired(file: expiredFileCredential, keychain: expiredKeychainCredential) {
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
    /// default. Shared with `AntigravityCredentials`.
    static let keychainOptInKey = "allowKeychainAccess"

    static var keychainAllowed: Bool {
        UserDefaults.standard.bool(forKey: keychainOptInKey)
    }

    private static let lastGood = Locked<LastGood?>(nil)
    private static let sessionKeychain = Locked<KeychainSessionState>(.unattempted)

    static var currentSessionState: KeychainSessionState {
        sessionKeychain.withLock { $0 }
    }

    /// Forgets the short-lived `lastGood` grace token (e.g. after HTTP 401 so
    /// file/snapshot sources are re-checked) WITHOUT resetting the keychain
    /// session cache — a background 401 never triggers a keychain read.
    static func invalidate() { lastGood.withLock { $0 = nil } }

    /// Clears both `lastGood` and the session keychain cache. Called only on
    /// wake-from-sleep or explicit user actions (Refresh Now, opt-in toggle,
    /// Forget).
    static func resetKeychainSession() {
        lastGood.withLock { $0 = nil }
        sessionKeychain.withLock { $0 = .unattempted }
    }

    private static let queue = DispatchQueue(label: "dev.notchstats.claude.credentials", qos: .utility)

    /// Background-safe resolution called by `ClaudeProvider.fetch()`. Performs
    /// zero `kSecReturnData` keychain calls.
    static func resolveAsync(force: Bool = false,
                             snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory()) async -> Resolution {
        if force { invalidate() }
        let cachedKeychain = sessionKeychain.withLock { $0 }
        let inputs = Inputs.live(keychainAllowed: keychainAllowed,
                                 sessionKeychain: cachedKeychain,
                                 snapshotDirectory: snapshotDirectory)
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

    /// Performs at most **one** non-interactive (`UIFail` + `LAContext`)
    /// Keychain secret read for the current session, and only when:
    /// - `keychainAllowed` is `true`,
    /// - no launch/session read has been attempted yet, and
    /// - neither env, plain file, nor a valid `0600` snapshot already holds an
    ///   unexpired token.
    ///
    /// A failed or denied read is remembered as `.refused` for the rest of the
    /// session so there is never a retry storm.
    static func warmFromKeychainIfAllowed(
        keychainAllowed allowed: Bool = keychainAllowed,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: @escaping @Sendable () -> FileRead = { Keychain.liveFileRead() },
        snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory(),
        readSecret: @escaping @Sendable () -> KeychainSecret = { Keychain.readSecret(interaction: .fail) },
        now: Date = Date()
    ) async {
        guard allowed else { return }
        guard sessionKeychain.withLock({ $0 == .unattempted }) else { return }

        // If env, plain file, or a valid 0600 snapshot already has a live
        // credential, skip the keychain completely.
        if hasLiveNonKeychainToken(environment: environment,
                                   readFile: readFile,
                                   snapshotDirectory: snapshotDirectory,
                                   now: now) {
            return
        }

        let state: KeychainSessionState = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: sessionState(from: readSecret()))
            }
        }
        sessionKeychain.withLock { $0 = state }
        if case let .credential(cred) = state, !cred.isExpired(now: now) {
            lastGood.withLock { $0 = LastGood(credential: cred, source: .keychain, at: now) }
        }
    }

    /// Explicit user-initiated capture ("Capture Claude login…" in the menu
    /// bar). This is the **only** Claude code path that may show a macOS
    /// Keychain password dialog. On success, writes an app-private `0600`
    /// snapshot file so every subsequent poll reads that file instead of the
    /// Keychain.
    @discardableResult
    static func captureFromKeychain(
        snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory(),
        readSecret: @escaping @Sendable () -> KeychainSecret = { Keychain.readSecret(interaction: .allow) },
        now: Date = Date()
    ) async -> CaptureResult {
        let secret: KeychainSecret = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readSecret()) }
        }
        switch secret {
        case let .found(data):
            switch parseCredential(from: data) {
            case let .credential(cred):
                do {
                    try CredentialSnapshotStore.write(provider: .claude,
                                                      accessToken: cred.token,
                                                      expiresAt: cred.expiresAt,
                                                      capturedAt: now,
                                                      directory: snapshotDirectory)
                } catch {
                    sessionKeychain.withLock { $0 = .credential(cred) }
                    return .writeFailed
                }
                sessionKeychain.withLock { $0 = .credential(cred) }
                if !cred.isExpired(now: now) {
                    lastGood.withLock { $0 = LastGood(credential: cred, source: .snapshot, at: now) }
                }
                return .captured(cred)
            case .cleared:
                sessionKeychain.withLock { $0 = .cleared }
                return .cleared
            case .malformed:
                sessionKeychain.withLock { $0 = .malformed }
                return .malformed
            }
        case .absent:
            sessionKeychain.withLock { $0 = .absent }
            return .absent
        case .refused:
            sessionKeychain.withLock { $0 = .refused }
            return .refused
        }
    }

    /// Deletes only NotchStats's own `0600` Claude snapshot file and forgets
    /// the in-memory session cache. Never touches `~/.claude/` or the Keychain.
    static func forgetSnapshot(snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory()) {
        CredentialSnapshotStore.delete(provider: .claude, directory: snapshotDirectory)
        resetKeychainSession()
    }

    private static func hasLiveNonKeychainToken(environment: [String: String],
                                                readFile: () -> FileRead,
                                                snapshotDirectory: URL,
                                                now: Date) -> Bool {
        if let raw = environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if case let .data(data) = readFile(),
           case let .credential(cred) = parseCredential(from: data),
           !cred.isExpired(now: now) {
            return true
        }
        if case let .valid(snap) = CredentialSnapshotStore.read(provider: .claude,
                                                                directory: snapshotDirectory,
                                                                now: now) {
            let cred = Credential(token: snap.accessToken,
                                  kind: .init(token: snap.accessToken),
                                  expiresAt: snap.expiresAtDate)
            if !cred.isExpired(now: now) { return true }
        }
        return false
    }

    private static func sessionState(from secret: KeychainSecret) -> KeychainSessionState {
        switch secret {
        case let .found(data):
            switch parseCredential(from: data) {
            case let .credential(cred): return .credential(cred)
            case .cleared: return .cleared
            case .malformed: return .malformed
            }
        case .absent: return .absent
        case .refused: return .refused
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
        /// `kSecReturnData` and sets **both** `kSecUseAuthenticationUIFail` and
        /// a non-interactive `LAContext` so macOS can never show a password or
        /// unlock dialog.
        ///
        /// Note: `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` (not
        /// `LAContext.interactionNotAllowed`) is what suppresses the legacy
        /// file-based login-keychain ACL prompt (`AclValidationContext`).
        static func probeQuery(service: String) -> [String: Any] {
            let context = LAContext()
            context.interactionNotAllowed = true
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
                kSecUseAuthenticationContext as String: context
            ]
        }

        /// Builds the secret-read query.
        ///
        /// `.fail` (default — every non-interactive / launch / wake read) sets
        /// **both** `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` and
        /// `LAContext.interactionNotAllowed = true`. `UIFail` — not `LAContext`
        /// — is what suppresses macOS's legacy login-keychain ACL dialog
        /// (`AclValidationContext(action:24)`) and turns a would-be password
        /// prompt into an immediate `errSecInteractionNotAllowed` error.
        ///
        /// `.allow` is used exclusively by the user-initiated "Capture Claude
        /// login…" menu action.
        static func secretQuery(service: String, interaction: Interaction = .fail) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if interaction == .fail {
                let context = LAContext()
                context.interactionNotAllowed = true
                // UIFail (not LAContext alone) is required to suppress legacy
                // login-keychain ACL password dialogs in securityd.
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
                query[kSecUseAuthenticationContext as String] = context
            }
            return query
        }

        /// Attributes only — no secret is requested, so this can never ask
        /// for a password. Both `UIFail`, `interactionNotAllowed`, and
        /// `SecKeychainSetUserInteractionAllowed(false)` also stop a locked
        /// keychain from showing an unlock dialog.
        static func probe() -> KeychainProbe {
            KeychainGuard.withInteraction(allowed: false) {
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
        }

        /// Reads the secret. With `.fail` (default), `KeychainGuard` sets
        /// `SecKeychainSetUserInteractionAllowed(false)` alongside `UIFail` and
        /// `LAContext.interactionNotAllowed = true` so macOS gets no chance to
        /// prompt; `.allow` is only used for the user's explicit Capture click.
        static func readSecret(interaction: Interaction = .fail) -> KeychainSecret {
            KeychainGuard.withInteraction(allowed: interaction == .allow) {
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
