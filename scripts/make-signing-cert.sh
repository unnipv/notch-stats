#!/usr/bin/env bash
# Create a self-signed code-signing certificate ("NotchStats Dev") in the macOS
# login keychain so ./build.sh can sign with a persistent identity instead of an
# ad-hoc CDHash that changes on every rebuild.
#
# Usage:
#   ./scripts/make-signing-cert.sh            # create & trust "NotchStats Dev"
#   ./scripts/make-signing-cert.sh --dry-run  # print commands without changing anything
#
# Environment overrides:
#   NOTCHSTATS_CERT_NAME   Certificate CN (default: "NotchStats Dev")
#   NOTCHSTATS_KEYCHAIN    Target keychain path (default: ~/Library/Keychains/login.keychain-db)

set -euo pipefail

CERT_NAME="${NOTCHSTATS_CERT_NAME:-NotchStats Dev}"
KEYCHAIN="${NOTCHSTATS_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

say() { printf '==> %s\n' "$1"; }
run_cmd() {
  printf '  $ %s\n' "$*"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

# 1. Idempotency check: if a valid code-signing identity already exists, stop.
EXISTING="$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
  | grep "\"$CERT_NAME\"" || true)"
if [ -n "$EXISTING" ]; then
  say "Signing identity \"$CERT_NAME\" is already installed and trusted:"
  printf '%s\n' "$EXISTING"
  say "./build.sh will auto-detect it automatically (or set NOTCHSTATS_SIGN_IDENTITY=\"$CERT_NAME\")."
  exit 0
fi

# Check if an untrusted certificate with the same name is already in the keychain.
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  say "A certificate named \"$CERT_NAME\" already exists in $KEYCHAIN, but is not yet trusted for Code Signing."
  cat <<EOF
To trust it without creating a duplicate:
  1. Open Keychain Access -> login -> My Certificates -> "$CERT_NAME".
  2. Expand "Trust" and set "Code Signing" to "Always Trust" (macOS will ask for your password once).
  3. Re-run this script to verify with: security find-identity -v -p codesigning
EOF
  exit 0
fi

cat <<EOF
==> Creating self-signed code-signing certificate "$CERT_NAME" in:
    $KEYCHAIN

Why:
  Ad-hoc signing (codesign -s -) pins Keychain "Always Allow" grants to a
  per-build CDHash, so every rebuild invalidates the grant. A persistent
  self-signed identity keeps the same designated requirement across rebuilds.

What to expect:
  macOS will display ONE authentication prompt asking for your login password
  when trusting this certificate for Code Signing (security add-trusted-cert).
  This is a one-time setup; subsequent ./build.sh runs are completely silent.
EOF

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_codesign
prompt = no

[req_dn]
CN = $CERT_NAME

[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# Use macOS's built-in /usr/bin/openssl (LibreSSL) so PKCS#12 uses legacy-safe
# ciphers accepted by macOS `security import` (OpenSSL 3 defaults require -legacy).
OPENSSL_BIN="/usr/bin/openssl"
if [ ! -x "$OPENSSL_BIN" ]; then
  OPENSSL_BIN="$(command -v openssl)"
fi

P12_PASS="$("$OPENSSL_BIN" rand -hex 16)"

say "Generating 2048-bit RSA self-signed code-signing certificate (valid 10 years)"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  $ %s req -x509 -newkey rsa:2048 -nodes -keyout <tmp>/key.pem -out <tmp>/cert.pem -days 3650 -config <tmp>/cert.cnf\n' "$OPENSSL_BIN"
  printf '  $ %s pkcs12 -export -inkey <tmp>/key.pem -in <tmp>/cert.pem -out <tmp>/identity.p12 -passout pass:<ephemeral>\n' "$OPENSSL_BIN"
  printf '  $ security import <tmp>/identity.p12 -k %s -P <ephemeral> -T /usr/bin/codesign -T /usr/bin/security\n' "$KEYCHAIN"
  printf '  $ security add-trusted-cert -r trustRoot -p codeSign -k %s <tmp>/cert.pem\n' "$KEYCHAIN"
  printf '  $ security find-identity -v -p codesigning %s\n' "$KEYCHAIN"
  say "Dry run complete; no keychain changes were made."
  exit 0
fi

"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -days 3650 \
  -config "$TMP/cert.cnf" 2>/dev/null

"$OPENSSL_BIN" pkcs12 -export \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" \
  -passout "pass:$P12_PASS"

say "Importing identity into $KEYCHAIN"
printf '  $ security import %s -k %s -P <ephemeral> -T /usr/bin/codesign -T /usr/bin/security\n' \
  "$TMP/identity.p12" "$KEYCHAIN"
security import "$TMP/identity.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

say "Trusting certificate for Code Signing (macOS will prompt for your login password once)"
if ! run_cmd security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  cat >&2 <<EOF

!! Could not update trust settings automatically (for example, in a headless/SSH
   session where macOS cannot display the password dialog).
   The identity was imported into $KEYCHAIN. To finish trusting it from a GUI
   Terminal session, run:
     security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > /tmp/notchstats-dev.pem
     security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" /tmp/notchstats-dev.pem
     rm -f /tmp/notchstats-dev.pem
EOF
  exit 1
fi

say "Verifying installed signing identity"
run_cmd security find-identity -v -p codesigning "$KEYCHAIN"
say "Done. Run ./build.sh to sign NotchStats.app with \"$CERT_NAME\"."
