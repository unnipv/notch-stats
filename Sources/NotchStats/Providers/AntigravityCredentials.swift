import Foundation
import LocalAuthentication
import Security

/// Reads the local Antigravity / Gemini OAuth token without ever modifying,
/// refreshing, locking, or deleting it, and without ever prompting macOS for a
/// Keychain password.
///
/// Sources, tried in order:
/// 1. `JETSKI_OAUTH_TOKEN` environment variable (matches `agy` CLI).
/// 2. macOS login Keychain item written by `agy` (`svce="gemini"`,
///    `acct="antigravity"`), read strictly non-interactively via `LAContext`
///    (`interactionNotAllowed = true`, never the `security` CLI).
/// 3. `~/.gemini/oauth_creds.json` (honouring `GEMINI_CLI_HOME` when set).
///
/// When both Keychain and file exist, an unexpired token always wins over an
/// expired one (for example, an old `~/.gemini/oauth_creds.json` left by Gemini
/// CLI never shadows a live `agy` Keychain login).
///
/// Strictly read-only: nothing here writes, refreshes, rotates, or deletes a
/// credential.
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
        case keychain = "keychain"
        case file = "credentials file"
        /// Last good credential kept briefly while a source is mid-rewrite.
        case lastKnown = "last known"
    }

    enum Failure: Equatable, Sendable {
        /// Neither Antigravity nor Gemini CLI has a login on this Mac.
        case notSignedIn
        /// The login Keychain is locked or refused a non-interactive read.
        case keychainDenied
        /// `~/.gemini/oauth_creds.json` exists but cannot be parsed yet.
        case fileUnreadable

        var issue: ProviderIssue {
            switch self {
            case .notSignedIn: return .notSignedIn
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

    enum FileRead: Equatable {
        case absent
        case unreadable
        case data(Data)
    }

    enum KeychainRead: Equatable {
        case absent
        case refused
        case data(Data)
    }

    enum ParseResult: Equatable {
        case credential(Credential)
        /// Valid JSON with an explicit empty `access_token` (signed-out clear).
        case cleared
        /// Unparseable, truncated, or unrecognised bytes.
        case malformed
    }

    struct Inputs {
        var environment: [String: String]
        var readKeychain: () -> KeychainRead
        var readFile: () -> FileRead

        static func live() -> Inputs {
            let env = ProcessInfo.processInfo.environment
            return Inputs(environment: env,
                          readKeychain: { Store.liveKeychainRead() },
                          readFile: { Store.liveFileRead(environment: env) })
        }
    }

    struct LastGood: Equatable {
        let credential: Credential
        let source: Source
        let at: Date
    }

    /// How long a good credential outlives a transient mid-write read error.
    static let graceLifetime: TimeInterval = 120

    /// Pure resolution — testable without touching the Keychain or home dir.
    static func resolve(_ inputs: Inputs, lastGood: LastGood?, now: Date = Date()) -> Resolution {
        if let raw = inputs.environment["JETSKI_OAUTH_TOKEN"] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return .found(Credential(token: token, expiresAt: nil), .environment)
            }
        }

        var keychainProblem = false
        var keychainCleared = false
        var expiredKeychain: Credential?

        switch inputs.readKeychain() {
        case .absent:
            break
        case .refused:
            keychainProblem = true
        case let .data(data):
            switch parseCredential(from: data) {
            case let .credential(credential):
                if !credential.isExpired(now: now) {
                    return .found(credential, .keychain)
                }
                expiredKeychain = credential
            case .cleared:
                keychainCleared = true
            case .malformed:
                keychainProblem = true
            }
        }

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

        // No live token was found; if at least one source has an expired token,
        // return the fresher one so the UI reports expiry rather than omitting
        // the row or attempting a refresh.
        if let chosen = fresherExpired(keychain: expiredKeychain, file: expiredFile) {
            return .found(chosen.credential, chosen.source)
        }

        let explicitlyCleared = keychainCleared || fileCleared
        if !explicitlyCleared,
           let lastGood, now.timeIntervalSince(lastGood.at) < graceLifetime,
           !lastGood.credential.isExpired(now: now) {
            return .found(lastGood.credential, .lastKnown)
        }

        if keychainProblem { return .missing(.keychainDenied) }
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

    private static let lastGood = Locked<LastGood?>(nil)

    static func invalidate() { lastGood.withLock { $0 = nil } }

    private static let queue = DispatchQueue(label: "dev.notchstats.antigravity.credentials", qos: .utility)

    static func resolveAsync(force: Bool = false) async -> Resolution {
        if force { invalidate() }
        let inputs = Inputs.live()
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

    // MARK: - Keychain and file access (strictly read-only, never prompts)

    enum Store {
        /// Keychain coordinates used by `agy` (via `zalando/go-keyring`).
        static let keychainService = "gemini"
        static let keychainAccount = "antigravity"

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

        /// Non-interactive Keychain query. Attaches an `LAContext` with
        /// `interactionNotAllowed = true` so macOS can never display a password
        /// or unlock dialog in the background.
        static func keychainQuery() -> [String: Any] {
            let context = LAContext()
            context.interactionNotAllowed = true
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]
        }

        static func liveKeychainRead() -> KeychainRead {
            var item: CFTypeRef?
            switch SecItemCopyMatching(keychainQuery() as CFDictionary, &item) {
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
