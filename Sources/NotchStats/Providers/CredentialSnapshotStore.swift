import Darwin
import Foundation

/// Minimal app-private credential snapshot captured explicitly by the user from
/// the menu bar ("Capture Claude login…" / "Capture Gemini login…").
///
/// Stored exclusively under:
/// `~/Library/Application Support/NotchStats/credentials/<provider>.json`
/// with directory mode `0700` and file mode `0600`. Contains only what `fetch()`
/// needs (`accessToken`, optional `expiresAt`, and `capturedAt`) — never refresh
/// tokens, ID tokens, emails, or other tools' metadata.
///
/// Nothing here ever reads, writes, or touches `~/.claude/`, `~/.gemini/`, or
/// any macOS Keychain item.
struct CredentialSnapshot: Codable, Equatable, Sendable {
    let accessToken: String
    /// Unix timestamp in seconds, when the token carries an expiry.
    let expiresAt: Double?
    /// Unix timestamp in seconds when the user captured this snapshot.
    let capturedAt: Double

    var expiresAtDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: $0) }
    }

    var capturedAtDate: Date {
        Date(timeIntervalSince1970: capturedAt)
    }

    func isStale(maxLifetime: TimeInterval, now: Date = Date()) -> Bool {
        if let expiresAtDate, expiresAtDate <= now { return true }
        if now.timeIntervalSince(capturedAtDate) > maxLifetime { return true }
        return false
    }
}

enum CredentialSnapshotStore {
    enum Provider: String, CaseIterable, Sendable {
        case claude
        case gemini

        var filename: String { "\(rawValue).json" }

        /// Upper bound on how long a captured access-token snapshot is trusted
        /// even if `expiresAt` was omitted. Matches each provider's OAuth
        /// access-token TTL (~8h for Claude Code, ~1h for Antigravity/Gemini).
        var maxLifetime: TimeInterval {
            switch self {
            case .claude: return 8 * 3600
            case .gemini: return 3600
            }
        }
    }

    enum ReadResult: Equatable, Sendable {
        case absent
        /// File exists, but the token has expired or exceeded the provider's
        /// token lifetime; callers must treat it as stale/absent.
        case stale
        case unreadable
        case valid(CredentialSnapshot)
    }

    enum WriteError: Error, Equatable {
        case directoryCreationFailed
        case openFailed(Int32)
        case writeFailed(Int32)
        case renameFailed(Int32)
    }

    /// `~/Library/Application Support/NotchStats/credentials`
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("NotchStats", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: true)
    }

    static func fileURL(for provider: Provider, directory: URL = defaultDirectory()) -> URL {
        directory.appendingPathComponent(provider.filename, isDirectory: false)
    }

    static func exists(provider: Provider, directory: URL = defaultDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: provider, directory: directory).path)
    }

    static func read(provider: Provider,
                     directory: URL = defaultDirectory(),
                     maxLifetime: TimeInterval? = nil,
                     now: Date = Date()) -> ReadResult {
        let url = fileURL(for: provider, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .unreadable }
        guard let snapshot = try? JSONDecoder().decode(CredentialSnapshot.self, from: data) else {
            return .unreadable
        }
        let token = snapshot.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .unreadable }
        if snapshot.isStale(maxLifetime: maxLifetime ?? provider.maxLifetime, now: now) {
            return .stale
        }
        return .valid(CredentialSnapshot(accessToken: token,
                                         expiresAt: snapshot.expiresAt,
                                         capturedAt: snapshot.capturedAt))
    }

    /// Atomically writes a `0600` snapshot file inside the `0700` app-private
    /// credentials directory. The temporary file is created with `O_EXCL` and
    /// mode `0600` before any bytes are written, so there is no window where
    /// the file is readable by other users.
    @discardableResult
    static func write(provider: Provider,
                      accessToken: String,
                      expiresAt: Date?,
                      capturedAt: Date = Date(),
                      directory: URL = defaultDirectory()) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw WriteError.directoryCreationFailed
        }
        _ = Darwin.chmod(directory.path, 0o700)

        let snapshot = CredentialSnapshot(
            accessToken: accessToken,
            expiresAt: expiresAt?.timeIntervalSince1970,
            capturedAt: capturedAt.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)

        let destination = fileURL(for: provider, directory: directory)
        let tempURL = directory.appendingPathComponent(".\(provider.filename).tmp.\(UUID().uuidString)")

        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if fd < 0 { throw WriteError.openFailed(errno) }

        var writeSucceeded = false
        defer {
            _ = Darwin.close(fd)
            if !writeSucceeded { _ = Darwin.unlink(tempURL.path) }
        }

        // Enforce 0600 explicitly regardless of process umask.
        _ = Darwin.fchmod(fd, mode_t(0o600))

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.writeFailed(errno)
                }
                written += n
            }
        }

        if Darwin.rename(tempURL.path, destination.path) != 0 {
            throw WriteError.renameFailed(errno)
        }
        writeSucceeded = true
        return destination
    }

    static func delete(provider: Provider, directory: URL = defaultDirectory()) {
        let url = fileURL(for: provider, directory: directory)
        _ = Darwin.unlink(url.path)
    }
}
