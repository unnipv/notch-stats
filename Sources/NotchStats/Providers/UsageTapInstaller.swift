import Darwin
import Foundation

/// Why installing or removing the usage tap failed, worded for an `NSAlert`.
enum UsageTapError: LocalizedError, Equatable {
    /// The settings file has content that isn't JSON. We never overwrite it:
    /// that content is the user's, and "fixing" it would destroy it.
    case unparseableSettings(path: String)
    /// Valid JSON, but not an object (`[]`, `"x"`, …).
    case settingsNotAnObject(path: String)
    /// Neither `~/.claude` nor `~/.gemini/antigravity-cli` exists.
    case nothingToInstall
    /// The file kept changing underneath us (the CLI was writing it) on both
    /// attempts; we stop rather than overwrite someone else's write.
    case concurrentEdit(path: String)
    case io(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unparseableSettings(path):
            return "\(path) isn't valid JSON, so NotchStats left it untouched. Fix or empty the file, then try again."
        case let .settingsNotAnObject(path):
            return "\(path) doesn't contain a JSON object, so NotchStats left it untouched."
        case .nothingToInstall:
            return "Neither Claude Code (~/.claude) nor agy (~/.gemini/antigravity-cli) is set up on this Mac."
        case let .concurrentEdit(path):
            return "\(path) changed while NotchStats was editing it, so nothing was overwritten. Please try again."
        case let .io(path, reason):
            return "Couldn't write \(path): \(reason)"
        }
    }
}

/// Installs and removes the usage tap: a helper script plus a `statusLine`
/// entry in Claude Code's and `agy`'s settings that pipes each render's JSON
/// payload through it.
///
/// Every path and the clock are injected so tests run entirely in temp
/// directories; `live()` is the only place real home-directory paths appear.
///
/// Safety rules, because these are someone else's settings files:
/// - every other key is preserved, and a timestamped backup is written before
///   each change;
/// - an existing custom status line is chained, not replaced, so it keeps
///   rendering;
/// - what was replaced is recorded in `install-state.json` so uninstall puts
///   back exactly the previous `statusLine` (or removes the key if there was
///   none);
/// - a non-empty file that isn't JSON is an error, never an overwrite.
struct UsageTapInstaller: Sendable {
    enum Status: Equatable, Sendable {
        /// Script present and every CLI that exists on this Mac is tapped.
        case installed
        /// Some, but not all, of the above — e.g. a settings file was edited
        /// by hand after install.
        case partial
        case notInstalled
    }

    static let scriptName = "notchstats-tap.sh"

    let claudeSettingsURL: URL
    let geminiSettingsURL: URL
    /// `~/Library/Application Support/NotchStats`
    let supportDirectory: URL
    /// `<support>/bin`
    let binDirectory: URL
    let now: @Sendable () -> Date

    init(claudeSettingsURL: URL,
         geminiSettingsURL: URL,
         supportDirectory: URL,
         binDirectory: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.claudeSettingsURL = claudeSettingsURL
        self.geminiSettingsURL = geminiSettingsURL
        self.supportDirectory = supportDirectory
        self.binDirectory = binDirectory ?? supportDirectory.appendingPathComponent("bin", isDirectory: true)
        self.now = now
    }

    /// The real paths, honouring `CLAUDE_CONFIG_DIR` like Claude Code does.
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: String = NSHomeDirectory()) -> UsageTapInstaller {
        let override = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let claudeDir = override.isEmpty
            ? (home as NSString).appendingPathComponent(".claude")
            : (override as NSString).expandingTildeInPath
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        return UsageTapInstaller(
            claudeSettingsURL: URL(fileURLWithPath: claudeDir, isDirectory: true)
                .appendingPathComponent("settings.json"),
            geminiSettingsURL: homeURL.appendingPathComponent(".gemini/antigravity-cli/settings.json"),
            supportDirectory: homeURL.appendingPathComponent("Library/Application Support/NotchStats",
                                                             isDirectory: true))
    }

    var scriptURL: URL { binDirectory.appendingPathComponent(Self.scriptName) }
    var stateURL: URL {
        supportDirectory.appendingPathComponent("tap/install-state.json")
    }

    private var targets: [(kind: UsageTapProviderKind, url: URL)] {
        [(.claude, claudeSettingsURL), (.gemini, geminiSettingsURL)]
    }

    /// A CLI counts as present when its config directory exists. We never
    /// create `~/.claude` or `~/.gemini/…` for a tool that isn't installed.
    private func isPresent(_ settingsURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path,
                                              isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Commands

    /// `'<bin>' claude` — quoted because the path contains "Application Support".
    func command(for kind: UsageTapProviderKind, chaining previous: String? = nil) -> String {
        let base = "\(Self.shellQuote(scriptURL.path)) \(kind.rawValue)"
        guard let previous, !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return "\(base) sh -c \(Self.shellQuote(previous))"
    }

    /// Ours only when the command *runs* our script: its first token must be
    /// a path ending in `/notchstats-tap.sh`. A user command that merely
    /// mentions the name (`echo notchstats-tap.sh`, their own wrapper) is not.
    static func isTapCommand(_ command: String?) -> Bool {
        guard let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return false }
        let token: Substring
        if trimmed.hasPrefix("'") {
            // We quote the path because it contains "Application Support", so
            // a quoted first token runs to the closing quote, not a space.
            let body = trimmed.dropFirst()
            guard let close = body.firstIndex(of: "'") else { return false }
            token = body[..<close]
        } else {
            token = trimmed.prefix { !$0.isWhitespace }
        }
        return token.hasSuffix("/" + scriptName)
    }

    /// The user's command we wrapped, recovered from our own quoting. Used only
    /// when `install-state.json` is gone; `nil` means nothing was chained.
    static func chainedCommand(in command: String, kind: UsageTapProviderKind) -> String? {
        let marker = "\(scriptName)' \(kind.rawValue) sh -c "
        guard let range = command.range(of: marker) else { return nil }
        let quoted = String(command[range.upperBound...])
        guard quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return nil }
        return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// POSIX single-quoting: safe for any byte sequence except NUL.
    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Status

    func status() -> Status {
        let present = targets.filter { isPresent($0.url) }
        let tapped = present.filter { target in
            guard let object = try? loadSettings(target.url).object else { return false }
            return Self.isTapCommand(Self.statusLineCommand(object))
        }
        let scriptInstalled = FileManager.default.isExecutableFile(atPath: scriptURL.path)
        if tapped.isEmpty {
            return FileManager.default.fileExists(atPath: stateURL.path) ? .partial : .notInstalled
        }
        return tapped.count == present.count && scriptInstalled ? .installed : .partial
    }

    // MARK: - Install

    func install() throws {
        let present = targets.filter { isPresent($0.url) }
        guard !present.isEmpty else { throw UsageTapError.nothingToInstall }

        try writeScript()
        var state = loadState()
        for target in present {
            // `installTarget` only changes a file whose status line isn't
            // ours, so the recorded `previous` is never our own command — and
            // the newest one wins if the user re-set theirs since last time.
            if let entry = try installTarget(target.kind, url: target.url) {
                state[target.kind.rawValue] = entry
            }
            // Saved after each file so a failure on the second still lets
            // uninstall revert the first.
            try saveState(state)
        }
    }

    /// Returns the state entry to record, or `nil` when already tapped.
    private func installTarget(_ kind: UsageTapProviderKind, url: URL) throws -> [String: Any]? {
        let applied = try edit(url) { loaded in
            var object = loaded.object
            let previousCommand = Self.statusLineCommand(object)
            if Self.isTapCommand(previousCommand) { return .unchanged }

            // Keep any other status-line options the user set (e.g. `padding`).
            var line = object["statusLine"] as? [String: Any] ?? [:]
            line["command"] = command(for: kind, chaining: previousCommand)
            switch kind {
            case .claude:
                line["type"] = "command"
            case .gemini:
                // Keep agy's own status line visible above ours (which prints
                // nothing unless chained).
                line["stack_with_default"] = true
            }
            object["statusLine"] = line
            return .write(object)
        }
        guard let loaded = applied else { return nil }
        // Recorded from the attempt that actually landed, so a retry after a
        // concurrent edit records what we really replaced.
        return ["settingsPath": url.path,
                "previous": loaded.object["statusLine"] ?? NSNull(),
                "existed": loaded.existed]
    }

    private func writeScript() throws {
        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw UsageTapError.io(path: scriptURL.path, reason: error.localizedDescription)
        }
    }

    // MARK: - Uninstall

    /// Restores each recorded `previous` status line, but only where the
    /// current one is still ours — if the user has since changed it by hand,
    /// their newer choice wins. Then removes the state file, the script and the
    /// captures, so a disabled tap can't keep feeding old numbers.
    func uninstall() throws {
        let state = loadState()
        for target in targets {
            let entry = state[target.kind.rawValue] as? [String: Any]
            // The state file lives in a user-writable folder, so a recorded
            // `settingsPath` is honoured only when it equals this kind's own
            // target — which makes the target the only file we ever edit. A
            // tampered state can't aim uninstall at another file.
            let url = target.url
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let weCreated = (entry?["existed"] as? Bool) == false

            try edit(url) { loaded in
                var object = loaded.object
                guard let current = Self.statusLineCommand(object), Self.isTapCommand(current) else {
                    return .unchanged
                }
                if let entry {
                    if let previous = entry["previous"], !(previous is NSNull) {
                        object["statusLine"] = previous
                    } else {
                        object.removeValue(forKey: "statusLine")
                    }
                } else if let inner = Self.chainedCommand(in: current, kind: target.kind),
                          var line = object["statusLine"] as? [String: Any] {
                    // No record (state file lost): unwrap our own chaining.
                    line["command"] = inner
                    object["statusLine"] = line
                } else {
                    object.removeValue(forKey: "statusLine")
                }
                // A file we created that now holds nothing is removed, not
                // left behind as `{}`.
                return weCreated && object.isEmpty ? .delete : .write(object)
            }
        }

        let fm = FileManager.default
        try? fm.removeItem(at: stateURL)
        try? fm.removeItem(at: scriptURL)
        let tapDirectory = stateURL.deletingLastPathComponent()
        for kind in UsageTapProviderKind.allCases {
            try? fm.removeItem(at: kind.fileURL(directory: tapDirectory))
        }
    }

    // MARK: - Guarded edits

    enum EditAction {
        case unchanged
        case write([String: Any])
        /// Remove the file: only for one we created that is now empty.
        case delete
    }

    /// Cheap "did someone else write this?" check: modification date + size
    /// of the real file (symlinks followed); `nil` when it doesn't exist.
    struct Fingerprint: Equatable {
        let modified: Date?
        let size: Int?
    }

    static func fingerprint(_ url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.resolvingSymlinksInPath().path) else { return nil }
        return Fingerprint(modified: attributes[.modificationDate] as? Date,
                           size: (attributes[.size] as? NSNumber)?.intValue)
    }

    /// Called just before a guarded edit commits. Tests use it to simulate the
    /// CLI writing the file mid-edit; `nil` in the app.
    var beforeCommit: (@Sendable (URL) -> Void)?

    /// Load → compute → backup → commit, with the file re-checked right before
    /// it is replaced. If the CLI wrote it in between, the same edit is
    /// re-applied to the new content once; a second change throws
    /// `.concurrentEdit` rather than looping or overwriting.
    ///
    /// Returns the settings the committed edit was computed from, or `nil`
    /// when the edit was `.unchanged`.
    @discardableResult
    private func edit(_ url: URL,
                      _ change: (_ loaded: (object: [String: Any], existed: Bool)) throws -> EditAction)
        throws -> (object: [String: Any], existed: Bool)? {
        for _ in 0..<2 {
            let before = Self.fingerprint(url)
            let loaded = try loadSettings(url)
            let action = try change(loaded)
            if case .unchanged = action { return nil }

            // A file we created and now delete holds only our key: no backup.
            if loaded.existed, case .write = action { try backup(url) }
            beforeCommit?(url)
            guard Self.fingerprint(url) == before else { continue }

            switch action {
            case .unchanged:
                return nil
            case let .write(object):
                try writeSettings(object, to: url)
            case .delete:
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw UsageTapError.io(path: url.path, reason: error.localizedDescription)
                }
            }
            return loaded
        }
        throw UsageTapError.concurrentEdit(path: url.path)
    }

    // MARK: - Settings I/O

    static func statusLineCommand(_ object: [String: Any]) -> String? {
        (object["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Missing or whitespace-only files read as `{}`; anything else must parse.
    private func loadSettings(_ url: URL) throws -> (object: [String: Any], existed: Bool) {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return ([:], false) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UsageTapError.io(path: path, reason: error.localizedDescription)
        }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ([:], true)
        }
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw UsageTapError.unparseableSettings(path: path)
        }
        guard let object = any as? [String: Any] else {
            throw UsageTapError.settingsNotAnObject(path: path)
        }
        return (object, true)
    }

    /// `<file>.notchstats-<unixts>.bak`, with a counter if two changes land in
    /// the same second, so no backup ever overwrites an earlier one.
    @discardableResult
    func backup(_ url: URL) throws -> URL {
        let stamp = Int(now().timeIntervalSince1970)
        var candidate = URL(fileURLWithPath: "\(url.path).notchstats-\(stamp).bak")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: "\(url.path).notchstats-\(stamp)-\(counter).bak")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: candidate)
        } catch {
            throw UsageTapError.io(path: candidate.path, reason: error.localizedDescription)
        }
        return candidate
    }

    /// Temp file in the same directory + `rename(2)`, so the CLI never reads a
    /// half-written file. Symlinks (dotfile repos) are followed so the link
    /// stays a link; the original file mode is kept.
    private func writeSettings(_ object: [String: Any], to url: URL) throws {
        let destination = url.resolvingSymlinksInPath()
        let path = destination.path
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw UsageTapError.io(path: path, reason: error.localizedDescription)
        }
        data.append(0x0A)

        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).notchstats-\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: mode ?? NSNumber(value: 0o644)], ofItemAtPath: temp.path)
        } catch {
            try? fm.removeItem(at: temp)
            throw UsageTapError.io(path: path, reason: error.localizedDescription)
        }
        if fm.fileExists(atPath: path) {
            // `replaceItemAt` keeps the original's xattrs, ACLs and creation
            // date, which a bare `rename(2)` would silently drop.
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
            } catch {
                try? fm.removeItem(at: temp)
                throw UsageTapError.io(path: path, reason: error.localizedDescription)
            }
        } else {
            guard rename(temp.path, path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: temp)
                throw UsageTapError.io(path: path, reason: reason)
            }
        }
    }

    private func loadState() -> [String: Any] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        return jsonObject(data) ?? [:]
    }

    private func saveState(_ state: [String: Any]) throws {
        try writeSettings(state, to: stateURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    // MARK: - Helper script

    /// `notchstats-tap.sh <claude|gemini> [passthrough command...]`
    ///
    /// Written for macOS's `/bin/bash` 3.2 with only BSD tools. It must never
    /// block or break the status line: every failure path still runs the
    /// passthrough (or exits 0), and the passthrough gets the same stdin payload
    /// so a chained custom status line keeps rendering.
    ///
    /// Concurrent sessions each get their own `mktemp` file. Only this run's
    /// temp file is removed on exit; leftovers from killed runs are swept once
    /// they're over a minute old, never while another render may be using them.
    static let script = #"""
    #!/bin/bash
    # notchstats-tap.sh <claude|gemini> [passthrough command...]
    # Installed by NotchStats ("Enable usage tap"). Saves the status-line JSON
    # payload for NotchStats, then runs the original status line, if any.
    umask 077
    kind="$1"; shift
    case "$kind" in claude|gemini) ;; *) kind="" ;; esac
    passthrough() {
      if [ $# -gt 0 ]; then exec "$@"; fi
      cat >/dev/null 2>&1
      exit 0
    }
    [ -n "$kind" ] || passthrough "$@"
    dir="$HOME/Library/Application Support/NotchStats/tap"
    mkdir -p "$dir" 2>/dev/null
    tmp="$(mktemp "$dir/.$kind.XXXXXX" 2>/dev/null)" || passthrough "$@"
    cat > "$tmp" || { rm -f "$tmp"; passthrough "$@"; }
    # cheap shape check only; the app validates JSON
    first=$(tr -d ' \t\r\n' < "$tmp" | cut -c1)
    if [ "$first" = "{" ]; then
      dest="$dir/$kind.json"
      cp "$tmp" "$dest.new.$$" 2>/dev/null && chmod 600 "$dest.new.$$" && mv -f "$dest.new.$$" "$dest"
      rm -f "$dest.new.$$" 2>/dev/null
    fi
    rc=0
    if [ $# -gt 0 ]; then "$@" < "$tmp"; rc=$?; fi
    rm -f "$tmp" 2>/dev/null
    find "$dir" -maxdepth 1 -name ".$kind.*" -mmin +1 -exec rm -f {} + 2>/dev/null
    exit $rc

    """#
}
