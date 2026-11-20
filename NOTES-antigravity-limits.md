# Antigravity / Gemini Limits — Endpoint & Credential Notes

**Date:** 2026-11-20  
**Target:** Google Antigravity (`agy` 1.5.13 / Antigravity IDE) & Gemini CLI read-only quota integration in NotchStats  
**Safety note:** All payloads below are redacted. No OAuth access token, refresh token, ID token, email address, writer ID, or GCP project ID is printed, logged, committed, or used in test fixtures.

---

## 1. Credential Discovery (Strictly Read-Only)

NotchStats never writes, refreshes, rotates, copies, locks, or deletes any Gemini or Antigravity credential, never spawns `/usr/bin/security`, and attaches `LAContext` with `interactionNotAllowed = true` to every Keychain query so macOS can never display a password prompt in the background.

Sources checked in order by `AntigravityCredentials`:

1. **`JETSKI_OAUTH_TOKEN` environment variable** (same override honoured by `agy`).
2. **macOS login Keychain item written by `agy`:**
   - `kSecClassGenericPassword`, `svce = "gemini"`, `acct = "antigravity"`.
   - `agy` uses `zalando/go-keyring`, which stores the JSON payload base64-encoded with a `go-keyring-base64:` prefix.
   - Verified with an ad-hoc signed standalone Swift binary that `SecItemCopyMatching` with `interactionNotAllowed = true` returns `errSecSuccess` (`0`) with zero UI prompt.
   - Redacted decoded shape:
     ```json
     {
       "auth_method": "consumer",
       "id_token_email": "<REDACTED_EMAIL>",
       "token": {
         "access_token": "<REDACTED_ACCESS_TOKEN>",
         "expires_in": 3599,
         "expiry": "2026-11-20T20:10:09.40579+05:30",
         "refresh_token": "<REDACTED_REFRESH_TOKEN>",
         "token_type": "Bearer"
       },
       "writer_id": "<REDACTED_WRITER_ID>"
     }
     ```
3. **Plain file fallback (`~/.gemini/oauth_creds.json`, honouring `GEMINI_CLI_HOME`):**
   - Used by Gemini CLI (`gemini`) and file-based fallback setups.
   - Redacted shape:
     ```json
     {
       "access_token": "<REDACTED_ACCESS_TOKEN>",
       "refresh_token": "<REDACTED_REFRESH_TOKEN>",
       "scope": "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile openid",
       "token_type": "Bearer",
       "id_token": "<REDACTED_ID_TOKEN>",
       "expiry_date": 1750830000000
     }
     ```
   - On this Mac, `~/.gemini/oauth_creds.json` held an expired June 2025 token while the Keychain item held the live `agy` token. `AntigravityCredentials.resolve` therefore prefers any unexpired token across Keychain and file before falling back to the fresher expired token (which is surfaced as `.tokenExpired` and never refreshed).
   - If neither Keychain nor file nor env var exists, `AntigravityProvider.fetch()` returns `nil` so the row is omitted cleanly.

---

## 2. Live Endpoints Probed & Chosen

`agy` logs (`~/.gemini/antigravity-cli/log/cli-*.log`) and the running `Antigravity.app` `language_server` both target **`https://daily-cloudcode-pa.googleapis.com`** with `/v1internal:` RPCs.

### Critical findings from live probing

1. **`daily-cloudcode-pa.googleapis.com` vs `cloudcode-pa.googleapis.com`:**
   - Both hosts returned HTTP `200` for the same OAuth token, **but only `daily-cloudcode-pa.googleapis.com` reflected live Antigravity quota consumption** (live `remainingFraction` ticked down from `0.9389` to `0.9252` with a rolling ~5-hour `resetTime` during an active `agy` session, whereas `cloudcode-pa.googleapis.com` returned `1.0` for every Gemini bucket).
   - NotchStats therefore targets `https://daily-cloudcode-pa.googleapis.com`.
2. **`User-Agent` enforcement:**
   - `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with `User-Agent: NotchStats` returned **HTTP `403`**.
   - Sending `User-Agent: antigravity/1.5.13 darwin/arm64` returned **HTTP `200`** with all 19 model buckets.
3. **Endpoints used by NotchStats:**
   - **`POST https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`** — called **once per launch** (cached in memory; invalidated only on manual refresh `⌘R` or wake from sleep) to fetch `paidTier` / `currentTier` (displayed as the row's plan note) and `cloudaicompanionProject`.
   - **`POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`** — called **once per poll tick** (~2 KB JSON) to fetch real per-model `remainingFraction` and `resetTime` buckets.
4. **Other endpoints probed (not called in steady state):**
   - `POST /v1internal:fetchAvailableModels`: returns the exact same per-model `quotaInfo` (`remainingFraction`, `resetTime`), wrapped inside a ~100 KB payload of experiment IDs and system prompts. `retrieveUserQuota` is ~50× smaller.
   - `POST /v1internal:retrieveUserQuotaSummary`: returns a `groups` summary, **but only included the 3P `"Claude and GPT models"` group (`3p-weekly`, `3p-5h`) — it omitted Gemini models altogether**.

---

## 3. Redacted Response Shapes

### `POST /v1internal:loadCodeAssist`

Request body:
```json
{
  "metadata": {
    "ideType": "ANTIGRAVITY",
    "platform": "PLATFORM_UNSPECIFIED",
    "pluginType": "GEMINI"
  }
}
```

Redacted HTTP 200 response:
```json
{
  "allowedTiers": [
    {
      "description": "Gemini-powered code suggestions and chat in multiple IDEs",
      "id": "free-tier",
      "isDefault": true,
      "name": "Antigravity"
    },
    {
      "description": "Unlimited coding assistant with the most powerful Gemini models",
      "id": "standard-tier",
      "name": "Antigravity",
      "userDefinedCloudaicompanionProject": true,
      "usesGcpTos": true
    }
  ],
  "cloudaicompanionProject": "<REDACTED_PROJECT_ID>",
  "currentTier": {
    "description": "Gemini-powered code suggestions and chat in multiple IDEs",
    "id": "free-tier",
    "name": "Antigravity",
    "upgradeSubscriptionText": "Upgrade to get 1,500 model requests per day with Gemini CLI and Gemini Code Assist's agent mode with Google AI Pro.",
    "upgradeSubscriptionType": "GOOGLE_ONE",
    "upgradeSubscriptionUri": "<REDACTED_UPGRADE_URI>"
  },
  "gcpManaged": false,
  "paidTier": {
    "description": "Google AI Pro",
    "id": "g1-pro-tier",
    "name": "Google AI Pro",
    "upgradeSubscriptionText": "You can upgrade to a Google AI Ultra plan to receive higher rate limits.",
    "upgradeSubscriptionUri": "https://antigravity.google/g1-upgrade"
  },
  "upgradeSubscriptionUri": "https://codeassist.google.com/upgrade"
}
```

### `POST /v1internal:retrieveUserQuota`

Request body: `{"project": "<REDACTED_PROJECT_ID>"}` (also succeeds with `{}`).

Redacted HTTP 200 response:
```json
{
  "buckets": [
    {
      "modelId": "claude-opus-5-5-high",
      "remainingFraction": 1,
      "resetTime": "2026-11-20T18:53:03Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "claude-sonnet-5-5-medium",
      "remainingFraction": 1,
      "resetTime": "2026-11-20T18:53:03Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "gpt-oss-120b-medium",
      "remainingFraction": 1,
      "resetTime": "2026-11-20T18:53:03Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "gemini-2.5-pro",
      "remainingFraction": 0.92516804,
      "resetTime": "2026-11-20T18:31:02Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "gemini-2.5-flash",
      "remainingFraction": 0.92516804,
      "resetTime": "2026-11-20T18:31:02Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "gemini-3-flash",
      "remainingFraction": 0.92516804,
      "resetTime": "2026-11-20T18:31:02Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "gemini-4-hydrogen-sonar",
      "remainingFraction": 0.92516804,
      "resetTime": "2026-11-20T18:31:02Z",
      "tokenType": "WTUS"
    },
    {
      "modelId": "tab_flash_lite_preview",
      "remainingFraction": 1,
      "tokenType": "WTUS"
    }
  ]
}
```

### `POST /v1internal:retrieveUserQuotaSummary` (probed, not called on poll)

Redacted HTTP 200 response:
```json
{
  "description": "Within each group, models share a weekly limit and a 5-hour limit. ...",
  "groups": [
    {
      "buckets": [
        {
          "bucketId": "3p-weekly",
          "displayName": "Weekly Limit Remaining",
          "remainingFraction": 1,
          "resetTime": "2026-11-27T13:51:31Z",
          "window": "weekly"
        },
        {
          "bucketId": "3p-5h",
          "displayName": "Five Hour Limit Remaining",
          "remainingFraction": 1,
          "resetTime": "2026-11-20T18:51:31Z",
          "window": "5h"
        }
      ],
      "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
      "displayName": "Claude and GPT models"
    }
  ]
}
```

---

## 4. What Is Real vs. What Google Does Not Expose

### Real data shown in the **Gemini** row
- **Gemini quota window** (`remainingFraction` + `resetTime` from `gemini-*` buckets):
  - When all Gemini models share one pool (as observed live on Google AI Pro), NotchStats collapses them into a single **`Gemini`** window.
  - If an account exposes separate Gemini Pro and Gemini Flash fractions/resets, NotchStats splits them honestly into **`Pro`** and **`Flash`** windows.
- **Partner quota window (`Partner`)**: tightest `remainingFraction` + `resetTime` across the 3P (`claude-*`, `gpt-*`) buckets returned by `retrieveUserQuota` (omitted when an account has no 3P buckets).
- **Plan / tier note**: `paidTier.name` (e.g. `Google AI Pro`, `Google AI Ultra`) or `currentTier` (`Free plan`) from `loadCodeAssist`.
- **Notch bar placement**: occupies the second slot on the left ear directly below Codex (the slot vacated by Codex's removed Weekly indicator), showing the headline Gemini remaining percentage and reset countdown on peek.

### Not exposed by Google (deliberately not invented)
- **No weekly Gemini quota window:** Neither `retrieveUserQuota` nor `retrieveUserQuotaSummary` exposes a weekly quota bucket for Gemini models (only 3P Claude/GPT models appeared in `retrieveUserQuotaSummary`).
- **No absolute request / token cap or remaining count:** `remainingAmount` was absent in every live bucket; only the normalized `remainingFraction` (`0...1`) is returned.
- **No dollar spend or credit balance:** Antigravity consumer plans expose fractional quota pools, not USD credits.
- **Missing `remainingFraction`:** Any bucket omitting `remainingFraction` is skipped rather than assumed to be `100%` or `0%`.

---

## 5. Polling Cadence & CPU Budget

- Runs strictly on `AppStore`'s existing ~60s + 0–8s jitter refresh loop (zero extra timers, zero subprocesses, staggered 1s per provider).
- **Tick 1 (launch / manual refresh / wake):** `loadCodeAssist` + `retrieveUserQuota` (2 requests).
- **Steady-state ticks:** `retrieveUserQuota` only (**1 HTTP request per ~60s tick**, ~2 KB response).
- **Failures:** HTTP `429`, `5xx`, and transport errors trigger per-provider exponential backoff (2m → 4m → 8m → 10m cap) while keeping the last good reading dimmed (`Last reading`). HTTP `401` re-reads live credential sources once and retries at most once if `agy` rotated the token mid-poll; otherwise surfaces `"Gemini login rejected"` without backoff.

---

## 6. What Breaks If Google Changes It

Because `/v1internal:*` is an undocumented private Google Code Assist API:

1. **`User-Agent` gate changes:** If Google bumps the minimum accepted `antigravity/...` User-Agent version, `retrieveUserQuota` will return HTTP `403`, which NotchStats surfaces as `"Gemini access denied"`.
2. **Endpoint host or RPC rename:** If `daily-cloudcode-pa.googleapis.com` or `/v1internal:retrieveUserQuota` is retired or moved (e.g. to `aicode.googleapis.com`), NotchStats will surface HTTP `404`/`5xx` or `"No data"` instead of a stale fabricated figure.
3. **Keychain layout change:** If `agy` moves away from `svce="gemini", acct="antigravity"` or changes its `go-keyring-base64:` `StoredToken` JSON schema, `AntigravityCredentials` will fall back to `~/.gemini/oauth_creds.json` or omit/report unreadable cleanly without prompting.
4. **Access-token expiry while `agy` is idle:** Google OAuth access tokens expire after ~1 hour (`expires_in: 3599`). Because NotchStats never refreshes tokens, an idle session where neither `agy` nor Antigravity IDE has refreshed the token yet will honestly report `"Gemini token expired"` (`"Open Antigravity or run agy to renew it"`) until the user runs `agy` or opens Antigravity.
