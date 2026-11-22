import Foundation

/// Which CLI a tap capture came from.
///
/// Each kind maps to one file the helper script (`notchstats-tap.sh`) rewrites
/// atomically on every status-line render:
/// `~/Library/Application Support/NotchStats/tap/<kind>.json`.
enum UsageTapProviderKind: String, CaseIterable, Sendable {
    case claude
    case gemini

    var filename: String { "\(rawValue).json" }

    func fileURL(directory: URL = UsageTap.defaultDirectory()) -> URL {
        directory.appendingPathComponent(filename, isDirectory: false)
    }
}

/// How much to trust a capture. A capture only changes while the CLI is
/// rendering its status line, so an old file means "nobody is using the CLI
/// right now", not "the numbers are wrong" — it is still the best reading we
/// have when there is no usable login.
enum TapFreshness: Equatable, Sendable {
    case fresh
    case stale
}

/// Reads the usage "tap": the JSON payload Claude Code and `agy` hand to a
/// status-line command on stdin, saved to disk by `notchstats-tap.sh`.
///
/// Why: both CLIs already know their real limit state and pass it to the status
/// line on every render. Reading it needs no credentials at all — no Keychain
/// ACL, no 8h/1h token rotation, no network request — so it is the most
/// reliable source NotchStats has for these two providers whenever the CLI has
/// been used recently.
///
/// The payload never carries a plan tier, so a tap reading never invents one.
enum UsageTap {
    /// What a payload says: its limit windows (never empty) and the model the
    /// CLI is using. The model stands in for the plan tier the tap lacks — it
    /// is real data from the payload, not a guess.
    struct TapReading: Sendable, Equatable {
        let windows: [UsageWindow]
        let note: String?
    }

    /// A capture parsed into a reading, plus the file's age.
    struct Capture: Sendable, Equatable {
        let kind: UsageTapProviderKind
        let data: Data
        let modifiedAt: Date
        /// The parsed payload. A capture with no windows is not a capture.
        let reading: TapReading

        var windows: [UsageWindow] { reading.windows }
    }

    /// Captures older than this are `.stale`. Claude re-renders its status line
    /// at least on every message; ten minutes of silence means the session is
    /// idle and the numbers may have moved elsewhere (another machine, the web).
    static let freshnessWindow: TimeInterval = 10 * 60

    /// `~/Library/Application Support/NotchStats/tap`. Built from the home
    /// directory, not `FileManager.urls(for:)`, because the helper script uses
    /// `$HOME/Library/Application Support/…` and both must agree.
    static func defaultDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/NotchStats/tap", isDirectory: true)
    }

    /// The latest capture for `kind`, or `nil` when the file is missing, empty,
    /// unparseable or has no limit data yet. Never throws.
    static func read(_ kind: UsageTapProviderKind,
                     directory: URL = defaultDirectory()) -> Capture? {
        let url = kind.fileURL(directory: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let reading: TapReading?
        switch kind {
        case .claude: reading = parseClaude(data)
        case .gemini: reading = parseAntigravity(data)
        }
        guard let reading else { return nil }
        return Capture(kind: kind, data: data, modifiedAt: modifiedAt, reading: reading)
    }

    /// `.fresh` when the capture is at most `freshnessWindow` old. A file
    /// stamped in the future (clock change) counts as fresh rather than stale.
    static func freshness(_ capture: Capture, now: Date = Date()) -> TapFreshness {
        now.timeIntervalSince(capture.modifiedAt) <= freshnessWindow ? .fresh : .stale
    }

    // MARK: - Pure parsing (unit-tested)

    /// Claude Code's `statusLine` payload → `5h` / `Weekly` windows.
    ///
    /// `rate_limits` is absent until the session's first API response and for
    /// API-key logins; both return `nil` so the caller falls back to its
    /// credential path instead of showing an empty row.
    static func parseClaude(_ data: Data) -> TapReading? {
        guard let object = jsonObject(data),
              let limits = object["rate_limits"] as? [String: Any], !limits.isEmpty else { return nil }

        func window(_ key: String, id: String, label: String) -> UsageWindow? {
            guard let dict = limits[key] as? [String: Any],
                  // `used_percentage` is 0...100, not a fraction.
                  let used = asDouble(dict["used_percentage"]) else { return nil }
            // `resets_at` is epoch seconds. An epoch-0 placeholder means
            // "unknown": the percentage is still real, so keep the window and
            // drop only the reset.
            let reset = asDouble(dict["resets_at"])
                .map { Date(timeIntervalSince1970: $0) }
                .flatMap { isPlaceholderReset($0) ? nil : $0 }
            return UsageWindow(id: id, label: label, percent: clamp(used / 100), resetsAt: reset)
        }

        let windows = [window("five_hour", id: "5h", label: "5h"),
                       window("seven_day", id: "7d", label: "Weekly")].compactMap { $0 }
        return windows.isEmpty ? nil : TapReading(windows: windows, note: modelNote(object))
    }

    /// `agy`'s `statusLine` payload → Gemini / Weekly (+ Partner) windows.
    ///
    /// Only the buckets below are mapped. Everything else is skipped on purpose:
    /// - `gemini-argon-wtu-weekly` is an internal pool `agy` itself doesn't
    ///   surface; showing it would add a row nobody can act on.
    /// - Unknown buckets have no agreed meaning, and a guessed label is worse
    ///   than a missing row.
    static func parseAntigravity(_ data: Data) -> TapReading? {
        guard let object = jsonObject(data),
              let quota = object["quota"] as? [String: Any], !quota.isEmpty else { return nil }

        struct Mapping {
            let key: String
            let id: String
            let label: String
            /// Partner (3P model) pools report `remaining_fraction: 1` with an
            /// epoch-0 reset when unused; only show them once actually used.
            let onlyWhenUsed: Bool
        }
        let mappings = [
            Mapping(key: "gemini-5h", id: "gemini", label: "Gemini", onlyWhenUsed: false),
            Mapping(key: "gemini-weekly", id: "gemini-wk", label: "Weekly", onlyWhenUsed: false),
            Mapping(key: "3p-5h", id: "partner", label: "Partner", onlyWhenUsed: true),
            Mapping(key: "3p-weekly", id: "partner-wk", label: "Partner weekly", onlyWhenUsed: true)
        ]

        let windows: [UsageWindow] = mappings.compactMap { mapping in
            guard let dict = quota[mapping.key] as? [String: Any],
                  let remaining = asDouble(dict["remaining_fraction"]) else { return nil }
            // Never render "resets 56 years ago": a placeholder reset becomes
            // "unknown", but the percentage beside it is still real.
            let reset = isoDate(dict["reset_time"] as? String)
                .flatMap { isPlaceholderReset($0) ? nil : $0 }
            // An unused or placeholder partner pool carries no reading worth a row.
            if mapping.onlyWhenUsed, reset == nil || remaining >= 1 { return nil }
            return UsageWindow(id: mapping.id, label: mapping.label,
                               percent: clamp(1 - remaining), resetsAt: reset)
        }
        return windows.isEmpty ? nil : TapReading(windows: windows, note: modelNote(object))
    }

    /// `model.display_name`, falling back to `model.id`; `nil` when absent.
    static func modelNote(_ object: [String: Any]) -> String? {
        guard let model = object["model"] as? [String: Any] else { return nil }
        for key in ["display_name", "id"] {
            if let value = (model[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        return nil
    }

    /// `agy` uses `1970-01-01T00:00:00Z` for "no reset scheduled". Anything
    /// before 2001 is treated the same: no real quota resets then.
    static func isPlaceholderReset(_ date: Date) -> Bool {
        date.timeIntervalSince1970 < 978_307_200
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    // MARK: - Provider readings

    /// The row a provider shows for a tap capture. A stale capture is dimmed
    /// ("Last reading") exactly like a kept `lastGood` reading, with its age as
    /// the hint. `note` is a better caller-supplied note (a cached plan tier);
    /// without one, the payload's model name is shown.
    static func usage(_ capture: Capture, id: String, name: String, accentHex: String, order: Int,
                      note: String?, stale: Bool, now: Date = Date()) -> ProviderUsage {
        var usage = ProviderUsage(id: id, name: name, accentHex: accentHex, order: order,
                                  windows: capture.windows, note: note ?? capture.reading.note, error: nil)
        if stale {
            usage.isStale = true
            usage.hint = "Usage tap · \(Format.ago(capture.modifiedAt, now: now)) old"
        }
        return usage
    }
}
