import Foundation

/// Google Antigravity / Gemini usage limits from the Google Code Assist
/// internal endpoints (`daily-cloudcode-pa.googleapis.com`):
///
/// - `POST /v1internal:loadCodeAssist` (cached once per launch for plan tier
///   and `cloudaicompanionProject`).
/// - `POST /v1internal:retrieveUserQuota` (one lightweight request per poll
///   tick returning per-model `remainingFraction` and `resetTime` buckets).
///
/// Credentials are read strictly read-only via `AntigravityCredentials` (never
/// refreshed or written). When Antigravity/Gemini is not installed or signed in,
/// `fetch()` returns `nil` so the row is omitted cleanly.
struct AntigravityProvider: UsageProvider {
    static let id = "antigravity"
    static let name = "Gemini"
    static let accent = "#4285F4"
    static let order = 2

    static let baseURL = "https://daily-cloudcode-pa.googleapis.com"
    static let loadCodeAssistURL = URL(string: "\(baseURL)/v1internal:loadCodeAssist")!
    static let retrieveUserQuotaURL = URL(string: "\(baseURL)/v1internal:retrieveUserQuota")!

    /// `daily-cloudcode-pa.googleapis.com` returns HTTP 403 for generic
    /// User-Agents and expects an `antigravity/...` client identifier.
    static let userAgent = "antigravity/1.5.13 darwin/arm64"

    var id: String { Self.id }
    var name: String { Self.name }
    var accentHex: String { Self.accent }
    var order: Int { Self.order }

    struct AccountContext: Equatable, Sendable {
        let tierNote: String?
        let projectID: String?
    }

    typealias Resolver = @Sendable (_ force: Bool) async -> AntigravityCredentials.Resolution
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    typealias TapReader = @Sendable () -> UsageTap.Capture?

    private static let sharedAccountCache = Locked<AccountContext?>(nil)

    static func invalidateCache() {
        sharedAccountCache.withLock { $0 = nil }
    }

    private let resolve: Resolver
    private let transport: Transport
    private let accountCache: Locked<AccountContext?>
    private let readTap: TapReader
    private let now: @Sendable () -> Date

    /// `tap` defaults to the live capture file only when the resolver is live
    /// too: a test that injects credentials must not pick up a real tap file
    /// from the developer's home directory.
    init(resolve: Resolver? = nil,
         transport: @escaping Transport = { request in try await Self.liveTransport(request) },
         accountCache: Locked<AccountContext?>? = nil,
         tap: TapReader? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolve = resolve ?? { force in await AntigravityCredentials.resolveAsync(force: force) }
        self.transport = transport
        self.accountCache = accountCache ?? Self.sharedAccountCache
        let liveTap: TapReader = { UsageTap.read(.gemini) }
        let noTap: TapReader = { nil }
        self.readTap = tap ?? (resolve == nil ? liveTap : noTap)
        self.now = now
    }

    private static func liveTransport(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    static func loadCodeAssistRequest(token: String) -> URLRequest {
        let body: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ]
        return postRequest(url: loadCodeAssistURL, token: token, body: body)
    }

    static func retrieveUserQuotaRequest(token: String, projectID: String?) -> URLRequest {
        var body: [String: Any] = [:]
        if let projectID, !projectID.isEmpty { body["project"] = projectID }
        return postRequest(url: retrieveUserQuotaURL, token: token, body: body)
    }

    private static func postRequest(url: URL, token: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        return request
    }

    /// Priority: fresh tap > live credentials > stale tap. A fresh tap is what
    /// `agy` itself just rendered, so it beats two network round-trips; a stale
    /// one only stands in when there is no usable credential at all.
    func fetch() async -> ProviderUsage? {
        let tap = readTap()
        let clock = now()
        if let tap, UsageTap.freshness(tap, now: clock) == .fresh {
            return tapUsage(tap, stale: false, now: clock)
        }

        let resolution = await resolve(false)
        guard case let .found(initialCredential, _) = resolution else {
            if let tap { return tapUsage(tap, stale: true, now: clock) }
            if case let .missing(failure) = resolution {
                // Omit the row when Antigravity / Gemini isn't installed or signed in.
                if failure == .notSignedIn { return nil }
                return Self.failure(failure)
            }
            return nil
        }

        if initialCredential.isExpired() {
            if let tap { return tapUsage(tap, stale: true, now: clock) }
            return Self.expired()
        }

        var activeCredential = initialCredential
        var retriedAfter401 = false

        do {
            var context = accountCache.withLock { $0 }
            if context == nil {
                var (data, status) = try await transport(Self.loadCodeAssistRequest(token: activeCredential.token))
                if status == 401, !retriedAfter401 {
                    retriedAfter401 = true
                    switch await retryCredential(after: activeCredential) {
                    case let .rotated(fresh):
                        activeCredential = fresh
                        (data, status) = try await transport(Self.loadCodeAssistRequest(token: activeCredential.token))
                    case let .stop(usage):
                        return usage
                    case .unchanged:
                        break
                    }
                }
                if status == 200 {
                    context = Self.parseAccountContext(data)
                    if let context { accountCache.withLock { $0 = context } }
                } else {
                    if status == 401 { AntigravityCredentials.invalidate() }
                    return Self.response(status: status, data: data, note: nil)
                }
            }

            var (data, status) = try await transport(
                Self.retrieveUserQuotaRequest(token: activeCredential.token, projectID: context?.projectID))
            if status == 401, !retriedAfter401 {
                retriedAfter401 = true
                switch await retryCredential(after: activeCredential) {
                case let .rotated(fresh):
                    activeCredential = fresh
                    (data, status) = try await transport(
                        Self.retrieveUserQuotaRequest(token: activeCredential.token, projectID: context?.projectID))
                case let .stop(usage):
                    return usage
                case .unchanged:
                    break
                }
            }
            if status == 401 { AntigravityCredentials.invalidate() }
            return Self.response(status: status, data: data, note: context?.tierNote)
        } catch {
            return Self.transportFailure(error)
        }
    }

    /// The tap names the model that is spending the quota; that is more useful
    /// than a plan tier and is always present. A tier note from an earlier
    /// `loadCodeAssist` only stands in when the payload has no model.
    private func tapUsage(_ capture: UsageTap.Capture, stale: Bool, now: Date) -> ProviderUsage {
        let note = capture.reading.note ?? accountCache.withLock { $0 }?.tierNote
        return UsageTap.usage(capture, id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order,
                              note: note, stale: stale, now: now)
    }

    private enum RetryOutcome {
        case rotated(AntigravityCredentials.Credential)
        case unchanged
        case stop(ProviderUsage?)
    }

    /// Re-reads live credential sources once after an HTTP 401 so an in-flight
    /// OAuth refresh by `agy` never flashes "Rejected".
    private func retryCredential(after old: AntigravityCredentials.Credential) async -> RetryOutcome {
        switch await resolve(true) {
        case let .found(fresh, _):
            if fresh.isExpired() { return .stop(Self.expired()) }
            return fresh.token != old.token ? .rotated(fresh) : .unchanged
        case let .missing(failure):
            return .stop(failure == .notSignedIn ? nil : Self.failure(failure))
        }
    }

    // MARK: - Failure states (unit-tested)

    static func failure(_ failure: AntigravityCredentials.Failure) -> ProviderUsage {
        switch failure {
        case .notSignedIn:
            return issue(.notSignedIn, "Not signed in to Gemini", "Sign in with Antigravity or `agy`")
        case .keychainNotAllowed:
            return issue(.keychainNotAllowed, "Gemini login found, not shared",
                         "Menu bar ▸ Capture Gemini login…")
        case .keychainDenied:
            return issue(.keychainDenied, "Keychain access denied",
                         "Menu bar ▸ Capture Gemini login…")
        case .fileUnreadable:
            return issue(.unreadable, "Gemini credentials unreadable", "File is being rewritten — retrying")
        }
    }

    static func expired() -> ProviderUsage {
        issue(.tokenExpired, "Gemini token expired", "Open Antigravity or run `agy` to renew it")
    }

    static func response(status: Int, data: Data, note: String? = nil) -> ProviderUsage {
        switch status {
        case 200:
            return parseQuota(data, note: note)
        case 401:
            return issue(.rejected, "Gemini login rejected", "Open Antigravity or run `agy` to sign in")
        case 403:
            return issue(.rejected, "Gemini access denied", "Check your Antigravity login or plan")
        case 429:
            return issue(.rateLimited, "Rate limited", "Retrying shortly")
        case 500...599:
            return issue(.unreachable, "Google unavailable", "HTTP \(status) — retrying")
        default:
            return failure("HTTP \(status)")
        }
    }

    static func transportFailure(_ error: Error) -> ProviderUsage {
        issue(.unreachable, "Can't reach Google", "Check your connection — retrying")
    }

    private static func issue(_ issue: ProviderIssue, _ message: String, _ hint: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order,
                 message: message, hint: hint, issue: issue)
    }

    static func failure(_ message: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order, message: message)
    }

    // MARK: - Pure parsing (unit-tested)

    static func parseAccountContext(_ data: Data) -> AccountContext? {
        guard let object = jsonObject(data) else { return nil }
        let project = (object["cloudaicompanionProject"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        let paidTier = object["paidTier"] as? [String: Any]
        let currentTier = object["currentTier"] as? [String: Any]
        let tierNote = tierLabel(paidTier) ?? tierLabel(currentTier)
        return AccountContext(tierNote: tierNote, projectID: project)
    }

    private static func tierLabel(_ dict: [String: Any]?) -> String? {
        guard let dict else { return nil }
        let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch id {
        case "free-tier":
            return "Free plan"
        case "g1-pro-tier":
            return name.isEmpty ? "Google AI Pro" : name
        case "g1-ultra-tier":
            return name.isEmpty ? "Google AI Ultra" : name
        default:
            return name.isEmpty ? nil : name
        }
    }

    private struct ParsedBucket {
        let modelID: String
        let remaining: Double
        let resetsAt: Date?

        var usedPercent: Double { max(0, min(1, 1 - remaining)) }
    }

    static func parseQuota(_ data: Data, note: String? = nil) -> ProviderUsage {
        guard let object = jsonObject(data) else { return failure("Parse error") }

        // Tolerate Google RPC error envelopes returned inside a 200 payload.
        if let error = object["error"] as? [String: Any] {
            let status = (error["status"] as? String)?.uppercased() ?? ""
            let code = Int(asDouble(error["code"]) ?? 0)
            if status == "RESOURCE_EXHAUSTED" || code == 429 {
                return issue(.rateLimited, "Rate limited", "Retrying shortly")
            }
            if status == "UNAUTHENTICATED" || code == 401 {
                return issue(.rejected, "Gemini login rejected", "Open Antigravity or run `agy` to sign in")
            }
            if status == "PERMISSION_DENIED" || code == 403 {
                return issue(.rejected, "Gemini access denied", "Check your Antigravity login or plan")
            }
        }

        guard let rawBuckets = object["buckets"] as? [[String: Any]] else {
            return failure("No data")
        }

        // Only keep buckets with an explicit numeric remainingFraction — never
        // fabricate a percentage or turn an unknown into 100%.
        let parsed: [ParsedBucket] = rawBuckets.compactMap { dict in
            guard let rawFraction = asDouble(dict["remainingFraction"]) else { return nil }
            let clamped = max(0, min(1, rawFraction))
            let modelID = (dict["modelId"] as? String ?? "").lowercased()
            let reset = isoDate(dict["resetTime"] as? String)
            return ParsedBucket(modelID: modelID, remaining: clamped, resetsAt: reset)
        }

        guard !parsed.isEmpty else { return failure("No data") }

        // Exclude internal/tab autocomplete entries when user-facing model buckets exist.
        let primary = parsed.filter { !isInternalModel($0.modelID) }
        let active = primary.isEmpty ? parsed : primary

        var geminiPro: [ParsedBucket] = []
        var geminiFlash: [ParsedBucket] = []
        var geminiOther: [ParsedBucket] = []
        var partner: [ParsedBucket] = []
        var other: [ParsedBucket] = []

        for bucket in active {
            if bucket.modelID.hasPrefix("gemini") {
                if bucket.modelID.contains("flash") || bucket.modelID.contains("lite") {
                    geminiFlash.append(bucket)
                } else if bucket.modelID.contains("pro") || bucket.modelID.hasPrefix("gemini-4") {
                    geminiPro.append(bucket)
                } else {
                    geminiOther.append(bucket)
                }
            } else if bucket.modelID.hasPrefix("claude") || bucket.modelID.hasPrefix("gpt") {
                partner.append(bucket)
            } else {
                other.append(bucket)
            }
        }

        var windows: [UsageWindow] = []

        let proPool = tightest(geminiPro + geminiOther)
        let flashPool = tightest(geminiFlash)

        if let pro = proPool, let flash = flashPool {
            if isSamePool(pro, flash) {
                let merged = tightest([pro, flash]) ?? pro
                windows.append(UsageWindow(id: "gemini", label: "Gemini",
                                           percent: merged.usedPercent, resetsAt: merged.resetsAt))
            } else {
                windows.append(UsageWindow(id: "gemini-pro", label: "Pro",
                                           percent: pro.usedPercent, resetsAt: pro.resetsAt))
                windows.append(UsageWindow(id: "gemini-flash", label: "Flash",
                                           percent: flash.usedPercent, resetsAt: flash.resetsAt))
            }
        } else if let gemini = proPool ?? flashPool {
            windows.append(UsageWindow(id: "gemini", label: "Gemini",
                                       percent: gemini.usedPercent, resetsAt: gemini.resetsAt))
        }

        if let thirdParty = tightest(partner) {
            windows.append(UsageWindow(id: "partner", label: "Partner",
                                       percent: thirdParty.usedPercent, resetsAt: thirdParty.resetsAt))
        }

        if windows.isEmpty, let fallback = tightest(other) {
            windows.append(UsageWindow(id: "quota", label: "Quota",
                                       percent: fallback.usedPercent, resetsAt: fallback.resetsAt))
        }

        return ProviderUsage(id: id, name: name, accentHex: accent, order: order,
                             windows: windows,
                             note: note,
                             error: windows.isEmpty ? "No data" : nil)
    }

    private static func isInternalModel(_ modelID: String) -> Bool {
        modelID.hasPrefix("tab_") || modelID.hasPrefix("chat_")
    }

    private static func isSamePool(_ lhs: ParsedBucket, _ rhs: ParsedBucket) -> Bool {
        guard abs(lhs.remaining - rhs.remaining) <= 0.001 else { return false }
        switch (lhs.resetsAt, rhs.resetsAt) {
        case (.none, .none):
            return true
        case let (.some(a), .some(b)):
            return abs(a.timeIntervalSince(b)) <= 60
        default:
            return false
        }
    }

    private static func tightest(_ buckets: [ParsedBucket]) -> ParsedBucket? {
        buckets.min { lhs, rhs in
            if abs(lhs.remaining - rhs.remaining) > 1e-6 {
                return lhs.remaining < rhs.remaining
            }
            switch (lhs.resetsAt, rhs.resetsAt) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            default: return false
            }
        }
    }
}
