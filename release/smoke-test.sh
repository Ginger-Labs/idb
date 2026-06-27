#!/usr/bin/env bash
#
# release/smoke-test.sh — assert the freshly built binaries actually work.
#
# A standalone harness (also reused by the skill-update plan to decide which
# workarounds a new build obsoletes). It exercises the BUILT companion + the
# BUILT wheel's `idb` — never whatever is already on PATH.
#
# Asserts:
#   1. idb_companion --version reports the NB version.
#   2. idb ui describe-all returns a non-empty accessibility hierarchy.
#   3. idb ui pinch <x> <y> <scale> --duration <d> exits 0.
#
# Connection: "direct" mode — given --companion-path + --udid, the idb client
# spawns the built companion itself (grpc-port 0, auto-discovered), so there is
# no port to manage here.
#
# Usage:
#   release/smoke-test.sh [--udid UDID] [--companion PATH] [--idb PATH]
#                         [--x N --y N --scale N --duration N]
#     --udid       target simulator (default: a booted one, else boot one).
#     --companion  companion binary (default: Build/Distribution/idb_companion).
#     --idb        idb client    (default: install the built wheel into a venv).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/version.sh
. "$SELF_DIR/version.sh"

log() { printf '[smoke] %s\n' "$*" >&2; }
die() { printf '[smoke] error: %s\n' "$*" >&2; exit 1; }

UDID=""
COMPANION="$NB_REPO_ROOT/Build/Distribution/idb_companion"
IDB=""
PX=100; PY=100; SCALE=2; DURATION=0.5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)      UDID="$2";      shift 2;;
    --companion) COMPANION="$2"; shift 2;;
    --idb)       IDB="$2";       shift 2;;
    --x)         PX="$2";        shift 2;;
    --y)         PY="$2";        shift 2;;
    --scale)     SCALE="$2";     shift 2;;
    --duration)  DURATION="$2";  shift 2;;
    *) die "unknown argument: $1";;
  esac
done

[[ -x "$COMPANION" ]] || die "companion not found/executable: $COMPANION (run build-companion.sh)"

CLEAN=()
cleanup() { local c; for c in "${CLEAN[@]:-}"; do [[ -n "$c" ]] && eval "$c" || true; done; }
trap cleanup EXIT

# --- idb client: use the built wheel unless one was supplied -------------
if [[ -z "$IDB" ]]; then
  WHEEL="$(ls -t "$NB_ARTIFACTS_DIR"/fb_idb-*.whl 2>/dev/null | head -1 || true)"
  [[ -n "$WHEEL" ]] || die "no --idb and no wheel in $NB_ARTIFACTS_DIR (run build-client.sh)"
  VENV="$(mktemp -d "${TMPDIR:-/tmp}/nb-smoke-venv.XXXXXX")"
  CLEAN+=("rm -rf '$VENV'")
  log "installing $(basename "$WHEEL") into a temp venv"
  "${NB_PYTHON:-python3.12}" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "$WHEEL"
  IDB="$VENV/bin/idb"
fi
[[ -x "$IDB" ]] || die "idb client not executable: $IDB"

# --- 1. companion --version (no simulator needed) ------------------------
log "1/3  idb_companion --version"
ver="$("$COMPANION" --version 2>/dev/null)" || die "idb_companion --version failed to run"
case "$ver" in
  *"$NB_VERSION"*) log "     ok: $ver";;
  *) die "version mismatch — expected to contain $NB_VERSION, got: $ver";;
esac

# --- simulator ------------------------------------------------------------
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next((x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"), ""))' 2>/dev/null || true)"
fi
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices available -j 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next((x["udid"] for k,v in d.items() if "iOS" in k for x in v), ""))' 2>/dev/null || true)"
  [[ -n "$UDID" ]] || die "no iOS simulator available; pass --udid"
  log "no booted sim — booting $UDID (will shut it down afterward)"
  CLEAN+=("xcrun simctl shutdown '$UDID' >/dev/null 2>&1")
fi
log "using simulator $UDID"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true   # no-op if already booted
xcrun simctl bootstatus "$UDID" >/dev/null 2>&1 || true

# direct mode: --companion-path is global (before the subcommand); --udid is a
# per-subcommand arg (appended after it).
run_idb() { "$IDB" --companion-path "$COMPANION" "$@" --udid "$UDID"; }

# --- 2. ui describe-all ---------------------------------------------------
log "2/3  idb ui describe-all"
out="$(run_idb ui describe-all 2>/dev/null)" || die "ui describe-all failed"
[[ -n "$out" ]] || die "ui describe-all returned an empty hierarchy"
log "     ok: $(printf '%s' "$out" | wc -c | tr -d ' ') bytes of hierarchy"

# --- 3. ui pinch (scale is POSITIONAL: pinch X Y SCALE) ------------------
log "3/3  idb ui pinch $PX $PY $SCALE --duration $DURATION"
run_idb ui pinch "$PX" "$PY" "$SCALE" --duration "$DURATION" || die "ui pinch exited non-zero"
log "     ok"

log "ALL PASSED — companion $NB_VERSION on simulator $UDID"
