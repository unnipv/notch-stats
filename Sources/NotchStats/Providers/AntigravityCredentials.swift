import Foundation
import LocalAuthentication
import Security

/// Reads the local Antigravity / Gemini OAuth token without ever modifying,
/// refreshing, locking, or deleting it, and without ever performing a Keychain
/// secret read during background polls.
///
/// Sources, tried in order on every poll (zero `kSecReturnData` calls):
/// 1. `JETSKI_OAUTH_TOKEN` environment variable (matches `agy` CLI),
/// 2. `~/.gemini/oauth_creds.json` (honouring `GEMINI_CLI_HOME`) — plain file,
/// 3. App-private `0600` snapshot under
///    `~/Library/Application Support/NotchStats/credentials/gemini.json`
///    (written only when the user clicks "Capture Gemini login…"),
/// 4. In-memory session cache populated only once at launch (if "Allow Keychain
///    Access" is on) or by an explicit user action / wake-from-sleep.
///
/// Respects the exact same `allowKeychainAccess` opt-in as `ClaudeCredentials`:
/// with the opt-in off, only the attributes-only probe runs (never
/// `kSecReturnData`), and every non-interactive query sets **both**
/// `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` and
/// `LAContext.interactionNotAllowed = true`. `UIFail` is what suppresses the
/// legacy login-keychain ACL dialog (`AclValidationContext(action:24)`).
///
/// Strictly read-only on Gemini / Antigravity's own files and Keychain items:
/// nothing here writes, refreshes, rotates, or deletes another app's credential.
enum AntigravityCredentials {

    struct Credential: Equatable, Sendable {
        let token: String
        let expiresAt: Date?

        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    enum Source: String, Equatable, Sendable {
        case environment = "environment"
        case file = "credentials file"
        case snapshot = "captured snapshot"
        case keychain = "keychain"
        /// Last good credential kept briefly while a source is mid-rewrite.
        case lastKnown = "last known"
    }

    enum Failure: Equatable, Sendable {
        /// Neither Antigravity nor Gemini CLI has a login on this Mac.
        case notSignedIn
        /// An `agy` Keychain login exists, but has not been captured/shared.
        case keychainNotAllowed
        /// The login Keychain is locked or refused a non-interactive read.
        case keychainDenied
        /// `~/.gemini/oauth_creds.json` exists but cannot be parsed yet.
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

    /// Answer to "is there an `agy` item in the keychain?" — attributes only.
    enum KeychainProbe: Equatable, Sendable {
        case present
        case absent
        case unknown
    }

    enum KeychainRead: Equatable, Sendable {
        case absent
        case refused
        case data(Data)
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

    enum ParseResult: Equatable, Sendable {
        case credential(Credential)
        /// Valid JSON with an explicit empty `access_token` (signed-out clear).
        case cleared
        /// Unparseable, truncated, or unrecognised bytes.
        case malformed
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
                          readFile: { Store.liveFileRead(environment: env) },
                          readSnapshot: { CredentialSnapshotStore.read(provider: .gemini, directory: snapshotDirectory) },
                          keychainAllowed: keychainAllowed,
                          sessionKeychain: sessionKeychain,
                          probeKeychain: { Store.probe() })
        }
    }

    struct LastGood: Equatable, Sendable {
        let credential: Credential
        let source: Source
        let at: Date
    }

    /// How long a good credential outlives a transient mid-write read error.
    static let graceLifetime: TimeInterval = 120

    /// Pure resolution — testable without touching the Keychain or home dir.
    /// Never performs a Keychain secret read (`kSecReturnData`).
    static func resolve(_ inputs: Inputs, lastGood: LastGood?, now: Date = Date()) -> Resolution {
        if let raw = inputs.environment["JETSKI_OAUTH_TOKEN"] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return .found(Credential(token: token, expiresAt: nil), .environment)
            }
        }

        // Plain file first (free and unprompted).
        var fileProblem = false
        var fileCleared = false
        var expiredFile: Credential?
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
                expiredFile = credential
            case .cleared:
                fileCleared = true
            case .malformed:
                fileProblem = true
            }
        }

        // App-private 0600 snapshot captured explicitly by the user.
        if case let .valid(snapshot) = inputs.readSnapshot() {
            let credential = Credential(token: snapshot.accessToken,
                                        expiresAt: snapshot.expiresAtDate)
            if !credential.isExpired(now: now) {
                return .found(credential, .snapshot)
            }
        }

        // In-memory session keychain cache (populated once at launch/wake when
        // opted in, or via explicit Capture) — never reads keychain bytes on
        // poll ticks.
        var keychainFailure: Failure?
        var keychainCleared = false
        var expiredKeychain: Credential?
        switch inputs.sessionKeychain {
        case let .credential(credential):
            if !credential.isExpired(now: now) {
                return .found(credential, .keychain)
            }
            expiredKeychain = credential
        case .cleared:
            keychainCleared = true
        case .malformed, .refused:
            keychainFailure = .keychainDenied
        case .absent:
            break
        case .unattempted:
            switch inputs.probeKeychain() {
            case .present: keychainFailure = .keychainNotAllowed
            case .unknown: keychainFailure = .keychainDenied
            case .absent: break
            }
        }

        // No live token was found; if no unshared/denied keychain login is
        // hiding a fresher login and at least one source has an expired token,
        // return the fresher one so the UI reports expiry rather than omitting
        // the row or attempting a refresh.
        if keychainFailure == nil,
           let chosen = fresherExpired(keychain: expiredKeychain, file: expiredFile) {
            return .found(chosen.credential, chosen.source)
        }

        let explicitlyCleared = keychainCleared || (fileCleared && (keychainFailure == nil || lastGood?.source == .file))
        if !explicitlyCleared,
           let lastGood, now.timeIntervalSince(lastGood.at) < graceLifetime,
           !lastGood.credential.isExpired(now: now) {
            return .found(lastGood.credential, .lastKnown)
        }

        if let keychainFailure { return .missing(keychainFailure) }
        if fileProblem { return .missing(.fileUnreadable) }
        return .missing(.notSignedIn)
    }

    private static func fresherExpired(keychain: Credential?, file: Credential?) -> (credential: Credential, source: Source)? {
        switch (keychain, file) {
        case let (.some(k), .some(f)):
            let kTime = k.expiresAt?.timeIntervalSince1970 ?? 0
            let fTime = f.expiresAt?.timeIntervalSince1970 ?? 0
            return fTime > kTime ? (f, .file) : (k, .keychain)
        case let (.some(k), .none):
            return (k, .keychain)
        case let (.none, .some(f)):
            return (f, .file)
        case (.none, .none):
            return nil
        }
    }

    // MARK: - State

    /// Shares the exact same `allowKeychainAccess` opt-in as Claude.
    static var keychainAllowed: Bool { ClaudeCredentials.keychainAllowed }

    private static let lastGood = Locked<LastGood?>(nil)
    private static let sessionKeychain = Locked<KeychainSessionState>(.unattempted)

    static var currentSessionState: KeychainSessionState {
        sessionKeychain.withLock { $0 }
    }

    /// Clears `lastGood` only (e.g. after HTTP 401) without triggering any
    /// Keychain read on background polls.
    static func invalidate() { lastGood.withLock { $0 = nil } }

    /// Clears both `lastGood` and the session keychain cache. Called only on
    /// wake-from-sleep or explicit user actions.
    static func resetKeychainSession() {
        lastGood.withLock { $0 = nil }
        sessionKeychain.withLock { $0 = .unattempted }
    }

    private static let queue = DispatchQueue(label: "dev.notchstats.antigravity.credentials", qos: .utility)

    /// Background-safe resolution called by `AntigravityProvider.fetch()`.
    /// Performs zero `kSecReturnData` keychain calls.
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
    /// Keychain secret read for the current session, gated by
    /// `allowKeychainAccess`, and only if no live env/file/snapshot token
    /// already exists. A denied/failed read is remembered for the rest of the
    /// session.
    static func warmFromKeychainIfAllowed(
        keychainAllowed allowed: Bool = keychainAllowed,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: @escaping @Sendable () -> FileRead = { Store.liveFileRead() },
        snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory(),
        readSecret: @escaping @Sendable () -> KeychainRead = { Store.readSecret(interaction: .fail) },
        now: Date = Date()
    ) async {
        guard allowed else { return }
        guard sessionKeychain.withLock({ $0 == .unattempted }) else { return }

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

    /// Explicit user-initiated capture ("Capture Gemini login…" in the menu
    /// bar). This is the **only** Gemini code path that may show a macOS
    /// Keychain password dialog. On success, writes an app-private `0600`
    /// snapshot file so every subsequent poll reads that file instead of the
    /// Keychain.
    @discardableResult
    static func captureFromKeychain(
        snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory(),
        readSecret: @escaping @Sendable () -> KeychainRead = { Store.readSecret(interaction: .allow) },
        now: Date = Date()
    ) async -> CaptureResult {
        let secret: KeychainRead = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readSecret()) }
        }
        switch secret {
        case let .data(data):
            switch parseCredential(from: data) {
            case let .credential(cred):
                do {
                    try CredentialSnapshotStore.write(provider: .gemini,
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

    /// Deletes only NotchStats's own `0600` Gemini snapshot file and forgets
    /// the in-memory session cache. Never touches `~/.gemini/` or the Keychain.
    static func forgetSnapshot(snapshotDirectory: URL = CredentialSnapshotStore.defaultDirectory()) {
        CredentialSnapshotStore.delete(provider: .gemini, directory: snapshotDirectory)
        resetKeychainSession()
    }

    private static func hasLiveNonKeychainToken(environment: [String: String],
                                                readFile: () -> FileRead,
                                                snapshotDirectory: URL,
                                                now: Date) -> Bool {
        if let raw = environment["JETSKI_OAUTH_TOKEN"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if case let .data(data) = readFile(),
           case let .credential(cred) = parseCredential(from: data),
           !cred.isExpired(now: now) {
            return true
        }
        if case let .valid(snap) = CredentialSnapshotStore.read(provider: .gemini,
                                                                directory: snapshotDirectory,
                                                                now: now) {
            let cred = Credential(token: snap.accessToken, expiresAt: snap.expiresAtDate)
            if !cred.isExpired(now: now) { return true }
        }
        return false
    }

    private static func sessionState(from read: KeychainRead) -> KeychainSessionState {
        switch read {
        case let .data(data):
            switch parseCredential(from: data) {
            case let .credential(cred): return .credential(cred)
            case .cleared: return .cleared
            case .malformed: return .malformed
            }
        case .absent: return .absent
        case .refused: return .refused
        }
    }

    // MARK: - Keychain and file access (strictly read-only)

    enum Store {
        /// Keychain coordinates used by `agy` (via `zalando/go-keyring`).
        static let keychainService = "gemini"
        static let keychainAccount = "antigravity"

        enum Interaction { case fail, allow }

        /// Resolves `~/.gemini/oauth_creds.json`, honouring `GEMINI_CLI_HOME`.
        static func credentialsFilePath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        homeDirectory: String = NSHomeDirectory()) -> String {
            let override = environment["GEMINI_CLI_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base: String
            if !override.isEmpty {
                base = (override as NSString).expandingTildeInPath
            } else {
                base = homeDirectory
            }
            return ((base as NSString).appendingPathComponent(".gemini") as NSString)
                .appendingPathComponent("oauth_creds.json")
        }

        static func liveFileRead(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 homeDirectory: String = NSHomeDirectory()) -> FileRead {
            let path = credentialsFilePath(environment: environment, homeDirectory: homeDirectory)
            guard FileManager.default.fileExists(atPath: path) else { return .absent }
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return .unreadable }
            return .data(data)
        }

        /// Attributes-only existence probe (never requests `kSecReturnData`).
        /// Sets **both** `kSecUseAuthenticationUIFail` and a non-interactive
        /// `LAContext` so macOS can never raise a password or unlock dialog.
        ///
        /// Note: `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` (not
        /// `LAContext.interactionNotAllowed`) is what suppresses the legacy
        /// file-based login-keychain ACL dialog (`AclValidationContext`).
        static func probeQuery() -> [String: Any] {
            let context = LAContext()
            context.interactionNotAllowed = true
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
                kSecUseAuthenticationContext as String: context
            ]
        }

        /// Secret-read Keychain query.
        ///
        /// `.fail` (default — every non-interactive / launch / wake read) sets
        /// **both** `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` and
        /// `LAContext.interactionNotAllowed = true`. `UIFail` — not `LAContext`
        /// — is what suppresses macOS's legacy login-keychain ACL dialog
        /// (`AclValidationContext(action:24)`) and turns a would-be password
        /// prompt into an immediate `errSecInteractionNotAllowed` error.
        ///
        /// `.allow` is used exclusively by the user-initiated "Capture Gemini
        /// login…" menu action.
        static func secretQuery(interaction: Interaction = .fail) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
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

        /// Attributes-only check that an `agy` login exists in the Keychain.
        static func probe() -> KeychainProbe {
            KeychainGuard.withInteraction(allowed: false) {
                var item: CFTypeRef?
                switch SecItemCopyMatching(probeQuery() as CFDictionary, &item) {
                case errSecSuccess:
                    return .present
                case errSecItemNotFound:
                    return .absent
                default:
                    return .unknown
                }
            }
        }

        static func readSecret(interaction: Interaction = .fail) -> KeychainRead {
            KeychainGuard.withInteraction(allowed: interaction == .allow) {
                var item: CFTypeRef?
                switch SecItemCopyMatching(secretQuery(interaction: interaction) as CFDictionary, &item) {
                case errSecSuccess:
                    if let data = item as? Data, !data.isEmpty { return .data(data) }
                    return .refused
                case errSecItemNotFound:
                    return .absent
                default:
                    return .refused
                }
            }
        }
    }

    // MARK: - Parsing

    /// Prefix `zalando/go-keyring` prepends on macOS when base64-encoding a
    /// Keychain secret.
    static let goKeyringPrefix = "go-keyring-base64:"

    static func parseCredential(from data: Data) -> ParseResult {
        let payload = unwrapPayload(data)
        guard let object = jsonObject(payload) else { return .malformed }

        // `agy` Keychain shape: { "token": { "access_token": ..., "expiry": ... } }
        // `~/.gemini/oauth_creds.json` shape: { "access_token": ..., "expiry_date": ... }
        let tokenObject = (object["token"] as? [String: Any]) ?? object

        guard let rawToken = (tokenObject["access_token"] as? String)
                ?? (tokenObject["accessToken"] as? String) else {
            return .malformed
        }

        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return .cleared }

        let expiresAt = expiry(tokenObject["expiry_date"])
            ?? expiry(tokenObject["expiryDate"])
            ?? expiry(tokenObject["expiresAt"])
            ?? expiry(tokenObject["expires_at"])
            ?? expiry(tokenObject["expiry"])

        return .credential(Credential(token: token, expiresAt: expiresAt))
    }

    static func credential(from data: Data) -> Credential? {
        guard case let .credential(credential) = parseCredential(from: data) else { return nil }
        return credential
    }

    private static func unwrapPayload(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(goKeyringPrefix) {
            let encoded = String(trimmed.dropFirst(goKeyringPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let decoded = Data(base64Encoded: encoded) { return decoded }
        }
        return data
    }

    private static func expiry(_ value: Any?) -> Date? {
        if let number = asDouble(value) {
            // Milliseconds since epoch (oauth_creds.json `expiry_date`); tolerate seconds too.
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        return isoDate(value as? String)
    }
}
