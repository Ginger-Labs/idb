#!/usr/bin/env bash
#
# release/sign.sh — code-sign the assembled companion distribution, in place.
#
# Signs every Mach-O in Build/Distribution: the Resources/ shim dylibs and the
# in-simulator SimulatorFrameworkBridge first (inner code), then idb-repl and
# idb_companion (outer). Ad-hoc by default — that is the MINIMUM required for the
# binary to execute on Apple Silicon at all; a real Developer ID additionally
# enables optional notarization.
#
# Run AFTER build-companion.sh and BEFORE the asset is tarred, so the shipped
# tarball carries the final signatures (release.sh re-tars after this step).
#
# Env:
#   CODESIGN_IDENTITY   signing identity (default "-", ad-hoc). For a
#                       Gatekeeper-friendly build set "Developer ID Application: …".
#   NB_ENTITLEMENTS     optional path to an entitlements plist.
#   NB_NOTARIZE=1       after signing with a real identity, submit to notarytool
#                       (needs NB_NOTARY_PROFILE). See note on stapling below.
#   NB_NOTARY_PROFILE   `xcrun notarytool` keychain profile name.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/version.sh
. "$SELF_DIR/version.sh"

log() { printf '[sign] %s\n' "$*" >&2; }
die() { printf '[sign] error: %s\n' "$*" >&2; exit 1; }

DIST="${1:-$NB_REPO_ROOT/Build/Distribution}"
[[ -d "$DIST" ]] || die "no distribution at $DIST (run build-companion.sh first)"

IDENTITY="${CODESIGN_IDENTITY:--}"

opts=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  # Hardened runtime + a secure timestamp are prerequisites for notarization.
  opts+=(--options runtime --timestamp)
  log "signing with identity: $IDENTITY"
else
  log "ad-hoc signing (CODESIGN_IDENTITY unset)"
fi
[[ -n "${NB_ENTITLEMENTS:-}" ]] && opts+=(--entitlements "$NB_ENTITLEMENTS")

sign_one() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  log "signing $(basename "$f")"
  codesign "${opts[@]}" "$f"
}

# Inner code first: shim dylibs + the in-simulator bridge, then resource bundles…
for f in "$DIST"/Resources/*.dylib "$DIST/Resources/SimulatorFrameworkBridge"; do
  sign_one "$f"
done
for b in "$DIST"/*.bundle; do
  sign_one "$b"
done
# …then the outer executables.
sign_one "$DIST/idb-repl"
sign_one "$DIST/idb_companion"

# --- Verify (A4 acceptance) ----------------------------------------------
log "verifying signatures"
codesign --verify --verbose=2 "$DIST/idb_companion" \
  || die "codesign --verify failed: idb_companion"
codesign --verify --verbose=2 "$DIST/Resources/SimulatorFrameworkBridge" \
  || die "codesign --verify failed: SimulatorFrameworkBridge"
log "verify OK — idb_companion + SimulatorFrameworkBridge"

# --- Optional notarization (real identity only) --------------------------
# Stapling note: `xcrun stapler` only works on app bundles / .dmg / .pkg, not a
# bare CLI tool or tarball. For this tarball distribution, notarytool registers
# the ticket with Apple and Gatekeeper validates it online on first run, so
# there is nothing to staple. Wrap in a .pkg/.dmg later if offline stapling is
# ever required.
if [[ "${NB_NOTARIZE:-0}" == "1" ]]; then
  [[ "$IDENTITY" != "-" ]] || die "NB_NOTARIZE=1 needs a real CODESIGN_IDENTITY"
  [[ -n "${NB_NOTARY_PROFILE:-}" ]] || die "NB_NOTARIZE=1 needs NB_NOTARY_PROFILE"
  notarize_zip="$(mktemp -d "${TMPDIR:-/tmp}/nb-notarize.XXXXXX")/idb_companion-${NB_VERSION}.zip"
  ditto -c -k --keepParent "$DIST" "$notarize_zip"
  log "submitting $notarize_zip to notarytool (profile: $NB_NOTARY_PROFILE)…"
  xcrun notarytool submit "$notarize_zip" --keychain-profile "$NB_NOTARY_PROFILE" --wait
  rm -rf "$(dirname "$notarize_zip")"
  log "notarization submitted (ticket validated online; nothing to staple for a bare tool)"
fi
