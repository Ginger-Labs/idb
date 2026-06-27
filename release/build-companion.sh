#!/usr/bin/env bash
#
# release/build-companion.sh — build idb_companion (Release) and assemble a
# self-contained, relocatable tarball.
#
#   stdout: the absolute path to the produced .tar.gz (machine-readable; the
#           orchestrator captures this).
#   stderr: all human-facing logs.
#
# Env:
#   NB_SKIP_BUILD=1   reuse an existing Build/Distribution (skip ./build.sh),
#                     e.g. to re-pack/re-verify without a full rebuild.
#   NB_ARTIFACTS_DIR  override the output dir (default Build/artifacts).
#
# How the bundle is self-contained: idb_companion links FBControlCore /
# XCTestBootstrap / FBSimulatorControl / FBDeviceControl / CompanionLib /
# IDBCompanionUtilities / IDBGRPCSwift as STATIC archives (MACH_O_TYPE=staticlib,
# -ObjC), so they are compiled into the executable — the dist ships no .framework
# at all. The only dynamic deps are Apple private frameworks (CoreSimulator,
# AccessibilityPlatformTranslation, …) resolved from the active Xcode at runtime;
# those are not ours to bundle and are the source of the documented Xcode coupling.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/version.sh
. "$SELF_DIR/version.sh"

log()  { printf '[build-companion] %s\n' "$*" >&2; }
die()  { printf '[build-companion] error: %s\n' "$*" >&2; exit 1; }

cd "$NB_REPO_ROOT"

DIST="$NB_REPO_ROOT/Build/Distribution"

# --- Build ----------------------------------------------------------------
if [[ "${NB_SKIP_BUILD:-0}" == "1" ]]; then
  log "NB_SKIP_BUILD=1 — reusing existing $DIST"
  [[ -x "$DIST/idb_companion" ]] || die "no existing build at $DIST (unset NB_SKIP_BUILD to build)"
else
  for tool in xcodegen protoc protoc-gen-swift; do
    command -v "$tool" >/dev/null 2>&1 \
      || die "missing build prerequisite: $tool — see release/RELEASING.md (H6)"
  done
  log "building companion $NB_COMPANION_VERSION via ./build.sh build (full build)"
  # NB_COMPANION_VERSION reaches the BuildInfo.swift run-script phase through the
  # environment; build.sh disables User Script Sandboxing so the phase can read it.
  export NB_COMPANION_VERSION
  ./build.sh build
fi

[[ -d "$DIST" ]] || die "expected $DIST after build (build.sh build_distribution did not run)"
for f in idb_companion idb-repl Resources/SimulatorFrameworkBridge; do
  [[ -e "$DIST/$f" ]] || die "incomplete distribution: missing $f"
done

# --- Relocatability assertion --------------------------------------------
# A clean bundle has NO load command or rpath pointing back into THIS repo's
# build tree. Apple/Xcode paths are expected and allowed; we fail only if a path
# under $NB_REPO_ROOT leaked in (which would break the bundle off this machine).
assert_relocatable() {
  local bin="$1" bad=""
  [[ -e "$bin" ]] || return 0
  bad+="$(otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -F "$NB_REPO_ROOT" || true)"
  bad+="$(otool -l "$bin" 2>/dev/null \
            | awk '/LC_RPATH/{r=1} r&&/^ *path /{print $2; r=0}' \
            | grep -F "$NB_REPO_ROOT" || true)"
  if [[ -n "$bad" ]]; then
    log "non-relocatable references in $bin:"
    printf '%s\n' "$bad" >&2
    die "build-tree paths leaked into $(basename "$bin") — bundle is NOT relocatable"
  fi
}

log "checking relocatability (otool -L / -l)…"
assert_relocatable "$DIST/idb_companion"
assert_relocatable "$DIST/idb-repl"
assert_relocatable "$DIST/Resources/SimulatorFrameworkBridge"
for dylib in "$DIST"/Resources/*.dylib; do
  assert_relocatable "$dylib"
done

# --- Pack -----------------------------------------------------------------
# Label the asset with the architectures actually present in the binary (the
# truth), not the host's. build.sh currently pins ARCHS=arm64; to ship universal
# you must change that hard-coded setting in build.sh's invoke_xcodebuild
# (ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO) — it cannot be overridden by env
# alone. lipo below then reports "x86_64-arm64" automatically.
ARCH="$(lipo -archs "$DIST/idb_companion" 2>/dev/null | tr ' ' '-')"
ARCH="${ARCH:-$(uname -m)}"
mkdir -p "$NB_ARTIFACTS_DIR"
ASSET="$NB_ARTIFACTS_DIR/idb_companion-${NB_VERSION}-${ARCH}.tar.gz"

log "packing $ASSET"
# Tar the CONTENTS of Distribution/ so idb_companion lands at the archive root
# (consumers extract straight into libexec). COPYFILE_DISABLE suppresses macOS
# AppleDouble (._*) entries. Mach-O code signatures are embedded in the binary,
# not in xattrs, so they survive the round-trip.
COPYFILE_DISABLE=1 tar -czf "$ASSET" -C "$DIST" .

# --- Relocation proof (A2 acceptance) ------------------------------------
# Extract to a DIFFERENT path and run --version. This proves the static closure
# + Swift runtime load cleanly off the build path and that the NB version stamp
# is present. (--version returns before any CoreSimulator dlopen, so it isolates
# our bundling from the Xcode-coupled runtime deps; full boot is smoke-test.sh.)
PROOF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nb-companion-proof.XXXXXX")"
trap 'rm -rf "$PROOF_DIR"' EXIT
tar -xzf "$ASSET" -C "$PROOF_DIR"
log "relocation proof: running $PROOF_DIR/idb_companion --version"
if ! ver_json="$("$PROOF_DIR/idb_companion" --version 2>/dev/null)"; then
  die "relocated idb_companion --version failed to run (dyld/signature error)"
fi
case "$ver_json" in
  *"\"version\":\"$NB_VERSION\""*|*"\"version\": \"$NB_VERSION\""*) : ;;
  *) die "relocated --version did not report $NB_VERSION; got: $ver_json" ;;
esac
log "relocation proof OK — $ver_json"

log "done: $ASSET ($(du -h "$ASSET" | cut -f1))"
printf '%s\n' "$ASSET"
