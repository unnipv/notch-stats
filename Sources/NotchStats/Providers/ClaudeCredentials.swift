import Foundation
import Security

/// Finds the credential Claude Code already wrote, without ever modifying it.
///
/// Sources, tried in order, each with its own time budget:
/// 1. the `CLAUDE_CODE_OAUTH_TOKEN` environment variable,
/// 2. Claude Code's own lookup — `/usr/bin/security find-generic-password`,
/// 3. the macOS keychain via the Security framework (never prompts),
/// 4. `~/.claude/.credentials.json`.
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
        case securityCLI = "security CLI"
        case keychain = "keychain"
        case file = "credentials file"
    }

    /// Why nothing was found. Kept apart so a *failed read* is never reported
    /// as a *missing login*.
    enum Failure: Equatable {
        case notSignedIn
        case keychainDenied
        case keychainTimedOut

        var issue: ProviderIssue {
            self == .notSignedIn ? .notSignedIn : .keychainDenied
        }
    }

    enum Resolution: Equatable {
        case found(Credential, Source)
        case missing(Failure)
    }

    /// What one lookup source reported.
    enum Outcome: Equatable {
        case found
        case notFound
        case denied
        case timedOut
    }

    // MARK: - Caching

    /// A found credential is reused for five minutes — unless it has expired,
    /// in which case Claude Code may have renewed it already. A failure is only
    /// remembered for seconds, so one locked keychain or slow read cannot make a
    /// perfectly good login look absent.
    enum CachePolicy {
        static let foundLifetime: TimeInterval = 300
        static let failureLifetime: TimeInterval = 10

        static func isFresh(_ resolution: Resolution, age: TimeInterval, now: Date = Date()) -> Bool {
            switch resolution {
            case let .found(credential, _):
                return age >= 0 && age < foundLifetime && !credential.isExpired(now: now)
            case .missing:
                return age >= 0 && age < failureLifetime
            }
        }
    }

    /// Picks the failure to report when no source produced a credential.
    /// Anything other than a clean "not found" means we don't *know* the login
    /// is gone, so it must not be called missing.
    static func failure(from outcomes: [Outcome]) -> Failure {
        if outcomes.contains(.denied) { return .keychainDenied }
        if outcomes.contains(.timedOut) { return .keychainTimedOut }
        return .notSignedIn
    }

    private static let state = Locked<(resolution: Resolution, at: Date)?>(nil)

    /// Forgets what was read, so the next resolve goes back to the keychain
    /// (after a 401, a wake, or a manual refresh).
    static func invalidate() { state.withLock { $0 = nil } }

    private static func remember(_ resolution: Resolution) -> Resolution {
        state.withLock { $0 = (resolution, Date()) }
        return resolution
    }

    // MARK: - Resolving

    /// Claude Code reads both of these services.
    private static let services = ["Claude Code-credentials", "Claude Code"]

    // Separate queues so a blocked attempt cannot stall the next one.
    private static let frameworkQueue = DispatchQueue(label: "dev.notchstats.claude.kc", qos: .utility)
    private static let cliQueue = DispatchQueue(label: "dev.notchstats.claude.cli", qos: .utility)

    /// Seconds each `security` invocation may run before it is killed.
    private static let cliTimeout: TimeInterval = 5

    static func resolveAsync(force: Bool = false) async -> Resolution {
        if force { invalidate() }
        if let hit = state.withLock({ $0 }),
           CachePolicy.isFresh(hit.resolution, age: Date().timeIntervalSince(hit.at)) {
            return hit.resolution
        }

        if let raw = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return .found(Credential(token: token, kind: .init(token: token), expiresAt: nil), .environment)
        }

        var outcomes: [Outcome] = []

        // Prefer the same lookup Claude Code performs: reading the keychain
        // through the Security framework can trigger a "enter your login
        // keychain password" dialog, which `security` avoids.
        let cli = await readViaCLI()
        if let credential = cli.credential { return remember(.found(credential, .securityCLI)) }
        outcomes.append(cli.outcome)

        if Task.isCancelled { return .missing(.keychainTimedOut) }

        let framework = await readViaFramework()
        if let credential = framework.credential { return remember(.found(credential, .keychain)) }
        outcomes.append(framework.outcome)

        if let data = fileData(), let credential = credential(from: data) {
            return remember(.found(credential, .file))
        }

        return remember(.missing(failure(from: outcomes)))
    }

    // MARK: - Sources

    private struct Read {
        var credential: Credential?
        var outcome: Outcome
    }

    /// Cancellation bridge: lets a cancelled task kill the `security` child
    /// that its worker thread is waiting on, so nothing outlives the request.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func attach(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            self.process = process
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
    }

    private static func readViaCLI() async -> Read {
        let job = Job()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cliQueue.async { continuation.resume(returning: cliCredential(job: job)) }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Mirrors Claude Code's own lookup.
    private static func cliCredential(job: Job) -> Read {
        var outcome = Outcome.notFound
        for service in services {
            if job.isCancelled { return Read(credential: nil, outcome: .timedOut) }
            let run = runSecurity(service: service, job: job)
            switch run.status {
            case .success:
                if let raw = run.output, let credential = credential(from: Data(raw.utf8)) {
                    return Read(credential: credential, outcome: .found)
                }
            case .notFound:
                break
            case .denied:
                outcome = .denied
            case .timedOut:
                if outcome != .denied { outcome = .timedOut }
            }
        }
        return Read(credential: nil, outcome: outcome)
    }

    private enum RunStatus { case success, notFound, denied, timedOut }

    /// `errSecItemNotFound` surfaces from `security` as exit status 44.
    static func status(forExit code: Int32) -> Outcome {
        switch code {
        case 0: return .found
        case 44: return .notFound
        default: return .denied
        }
    }

    private static func runSecurity(service: String, job: Job) -> (status: RunStatus, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", service]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard job.attach(process) else { return (.timedOut, nil) }
        do {
            try process.run()
        } catch {
            return (.denied, nil)
        }

        if exited.wait(timeout: .now() + cliTimeout) == .timedOut {
            // A keychain prompt is holding it. Kill it rather than leak the
            // thread and the child.
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return (.timedOut, nil)
        }

        if job.isCancelled { return (.timedOut, nil) }

        // The credential is a few hundred bytes — far below the pipe buffer —
        // so reading after exit cannot deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        switch status(forExit: process.terminationStatus) {
        case .found:
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? (.notFound, nil) : (.success, value)
        case .notFound: return (.notFound, nil)
        default: return (.denied, nil)
        }
    }

    private static func readViaFramework() async -> Read {
        await withCheckedContinuation { continuation in
            frameworkQueue.async { continuation.resume(returning: frameworkCredential()) }
        }
    }

    private static func frameworkCredential() -> Read {
        var outcome = Outcome.notFound
        for service in services {
            let (data, status) = keychainData(service: service)
            if let data, let credential = credential(from: data) {
                return Read(credential: credential, outcome: .found)
            }
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed
                || status == errSecUserCanceled || status == errSecNotAvailable {
                outcome = .denied
            }
        }
        return Read(credential: nil, outcome: outcome)
    }

    private static func keychainData(service: String) -> (Data?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Fail fast instead of blocking on an approval dialog; the call
            // then needs no timeout and can never strand a thread.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return (nil, status) }
        return (item as? Data, status)
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
