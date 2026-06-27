#!/usr/bin/env bash
#
# release/version.sh — single source of truth for the NB idb release version.
#
#   Source it to import the variables:   . release/version.sh
#   Run it to print a summary:           ./release/version.sh
#
# Versioning model: "pinning" the upstream commit just means whatever SHA is
# checked out. The version is a base marketing version plus the short SHA, so
# every pinned build is uniquely identifiable and the client and companion stay
# in lockstep (they share the pinned proto — skew breaks them).

# Resolve paths from this script's own location so callers can source it from
# any working directory.
NB_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NB_REPO_ROOT="$(cd "$NB_RELEASE_DIR/.." && pwd)"

# Bump by hand when cutting a new marketing line.
NB_BASE_VERSION="1.1.8"

if ! NB_SHA="$(git -C "$NB_REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  echo "release/version.sh: $NB_REPO_ROOT is not a git repository" >&2
  return 1 2>/dev/null || exit 1
fi

# Human-facing version — used EVERYWHERE except the wheel: git tag, GitHub
# release, asset filenames, brew formula, `idb_companion --version`, libexec dir.
# URL-, brew-, and filesystem-safe (deliberately no '+').
NB_VERSION="${NB_BASE_VERSION}-nb-${NB_SHA}"

# Wheel version ONLY. PEP 440 cannot attach an arbitrary (hex) build id except
# via a local-version segment, which MUST use '+' — setuptools rejects
# '1.1.8-nb-<sha>' as an invalid version. pip therefore reports the client as
# '1.1.8+nb.<sha>'. This is the single, unavoidable place the '+' survives.
FB_IDB_VERSION="${NB_BASE_VERSION}+nb.${NB_SHA}"

# Git tag for the release.
NB_TAG="v${NB_VERSION}"

# Surfaced by `idb_companion --version` via the BuildInfo.swift stamp
# (see idb_companion/project.yml). build-companion.sh exports this before
# invoking ./build.sh so the run-script build phase can read it.
NB_COMPANION_VERSION="${NB_VERSION}"

# Where build-companion.sh / build-client.sh drop release assets. Lives under
# Build/ (gitignored), so artifacts are never accidentally committed.
NB_ARTIFACTS_DIR="${NB_ARTIFACTS_DIR:-$NB_REPO_ROOT/Build/artifacts}"

export NB_RELEASE_DIR NB_REPO_ROOT NB_BASE_VERSION NB_SHA NB_VERSION \
  FB_IDB_VERSION NB_TAG NB_COMPANION_VERSION NB_ARTIFACTS_DIR

# Print a summary only when executed directly (not when sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cat <<EOF
NB_VERSION         $NB_VERSION
FB_IDB_VERSION     $FB_IDB_VERSION   (wheel metadata / PEP 440 only)
NB_TAG             $NB_TAG
NB_SHA             $NB_SHA
NB_ARTIFACTS_DIR   $NB_ARTIFACTS_DIR
EOF
fi
