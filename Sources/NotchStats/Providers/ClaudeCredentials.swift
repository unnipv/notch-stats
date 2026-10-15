import Foundation
import Security

/// Finds the credential Claude Code already wrote, without ever modifying it.
///
/// Sources, tried in order, each with its own time budget:
/// 1. the `CLAUDE_CODE_OAUTH_TOKEN` environment variable,
/// 2. the macOS keychain via the Security framework,
/// 3. Claude Code's own lookup — `/usr/bin/security find-generic-password`,
/// 4. `~/.claude/.credentials.json`.
///
/// Two kinds of credential turn up in practice and they behave differently: an
/// **OAuth token** (`sk-ant-oat…`, Pro/Max login) can report usage limits, while
/// an **API key** (`sk-ant-api…`) belongs to an API organisation, where
/// Anthropic reports that usage limits do not apply.
enum ClaudeCredentials {
    enum Kind {
        case oauth
        case apiKey

        init(token: String) {
            self = token.contains("-oat") ? .oauth : .apiKey
        }
    }

    struct Credential {
        let token: String
        let kind: Kind
        let expiresAt: Date?
    }

    enum Source: String {
        case environment = "environment"
        case keychain = "keychain"
        case securityCLI = "security CLI"
        case file = "credentials file"
    }

    enum Resolution {
        case found(Credential, Source)
        case missing(String)
    }

    /// Claude Code reads both of these services.
    private static let services = ["Claude Code-credentials", "Claude Code"]

    // Separate queues so a blocked attempt cannot stall the next one. A keychain
    // read can block indefinitely on a macOS approval prompt.
    private static let frameworkQueue = DispatchQueue(label: "dev.notchstats.claude.kc", qos: .utility)
    private static let cliQueue = DispatchQueue(label: "dev.notchstats.claude.cli", qos: .utility)

    private static var cached: (resolution: Resolution, at: Date)?
    private static let cacheLifetime: TimeInterval = 300

    private static func cache(_ resolution: Resolution) -> Resolution {
        cached = (resolution, Date())
        return resolution
    }

    /// Drops the cache so the next resolve re-reads the keychain (e.g. after a 401).
    static func invalidate() { cached = nil }

    static func resolveAsync(force: Bool = false) async -> Resolution {
        if !force, let cached, Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.resolution
        }
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .found(Credential(token: raw, kind: .init(token: raw), expiresAt: nil), .environment)
        }

        // Prefer the same lookup Claude Code performs. Reading the keychain
        // through the Security framework instead triggers a "enter your login
        // keychain password" dialog, which `security` avoids.
        if let credential = await bounded(seconds: 6, on: cliQueue, cliCredential) ?? nil {
            return cache(.found(credential, .securityCLI))
        }

        let framework: (credential: Credential?, denied: Bool) =
            await bounded(seconds: 2.5, on: frameworkQueue, frameworkCredential) ?? (nil, false)
        if let credential = framework.credential { return cache(.found(credential, .keychain)) }

        if let data = fileData(), let credential = credential(from: data) {
            return cache(.found(credential, .file))
        }

        if framework.denied {
            return .missing("Keychain access denied — allow NotchStats when prompted")
        }
        return .missing("No Claude credentials — run `claude` to sign in")
    }

    /// Runs `work` on `queue`, returning nil if it does not finish in time.
    private static func bounded<T: Sendable>(seconds: Double,
                                             on queue: DispatchQueue,
                                             _ work: @escaping @Sendable () -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: work()) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Sources

    private static func frameworkCredential() -> (credential: Credential?, denied: Bool) {
        var denied = false
        for service in services {
            let (data, status) = keychainData(service: service)
            if let data, let credential = credential(from: data) { return (credential, denied) }
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed { denied = true }
        }
        return (nil, denied)
    }

    private static func keychainData(service: String) -> (Data?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return (nil, status) }
        return (item as? Data, status)
    }

    /// Mirrors Claude Code's own lookup.
    private static func cliCredential() -> Credential? {
        for service in services {
            guard let raw = runSecurity(service: service) else { continue }
            if let credential = credential(from: Data(raw.utf8)) { return credential }
        }
        return nil
    }

    private static func runSecurity(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", service]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func fileData() -> Data? {
        FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/.credentials.json")
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
