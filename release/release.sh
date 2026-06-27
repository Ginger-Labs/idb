#!/usr/bin/env bash
#
# release/release.sh — end-to-end NB idb release orchestrator.
#
# Builds both halves, signs, publishes a GitHub release on this fork, renders the
# Homebrew formula, and publishes it per DISTRIB_MODE. Idempotent and safe to
# re-run: an existing release is updated (assets clobbered) rather than duplicated.
#
# Required env:
#   DISTRIB_MODE        tap | url   (see release/RELEASING.md)
#   NB_TAP_DIR          (tap mode only) local clone of the homebrew-nb tap.
# Optional env:
#   CODESIGN_IDENTITY   passed through to sign.sh (default "-", ad-hoc).
#   NB_REPO_SLUG        GitHub slug of this fork (default: derived from origin).
#   NB_DRY_RUN=1        do everything LOCAL (build, sign, render) but skip every
#                       outward-facing action (gh release, git commit/push/tag).
#   NB_ALLOW_DIRTY=1    allow releasing from a dirty working tree (NOT advised —
#                       the version SHA then misrepresents what was built).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/version.sh
. "$SELF_DIR/version.sh"

log()  { printf '[release] %s\n' "$*" >&2; }
die()  { printf '[release] error: %s\n' "$*" >&2; exit 1; }

NB_DRY_RUN="${NB_DRY_RUN:-0}"
# Wrap ONLY outward-facing, hard-to-undo actions. Local build/sign/render always run.
run() {
  if [[ "$NB_DRY_RUN" == "1" ]]; then
    printf '[release][dry-run] would run: %s\n' "$*" >&2
  else
    printf '[release][run] %s\n' "$*" >&2
    "$@"
  fi
}

cd "$NB_REPO_ROOT"

# --- Preflight ------------------------------------------------------------
DISTRIB_MODE="${DISTRIB_MODE:-}"
case "$DISTRIB_MODE" in
  tap) [[ -n "${NB_TAP_DIR:-}" ]] || die "DISTRIB_MODE=tap requires NB_TAP_DIR (the tap clone)";;
  url) ;;
  *) die "set DISTRIB_MODE=tap or DISTRIB_MODE=url";;
esac

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

# Only tracked-file changes matter — stray untracked files (a PLAN doc, agent
# worktrees, scratch) must not block a release.
if [[ -n "$(git status --porcelain --untracked-files=no)" && "${NB_ALLOW_DIRTY:-0}" != "1" ]]; then
  die "tracked files have uncommitted changes — commit the build (incl. fork patches) first, or set NB_ALLOW_DIRTY=1"
fi

NB_REPO_SLUG="${NB_REPO_SLUG:-$(git remote get-url origin \
  | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')}"
[[ "$NB_REPO_SLUG" == */* ]] || die "could not derive NB_REPO_SLUG from origin; set it explicitly"

BUILD_SHA="$(git rev-parse HEAD)"
DRYNOTE=""; [[ "$NB_DRY_RUN" == "1" ]] && DRYNOTE=", dry-run"
log "releasing $NB_VERSION (tag $NB_TAG) from $NB_REPO_SLUG @ ${BUILD_SHA:0:9}  [mode=$DISTRIB_MODE$DRYNOTE]"

# --- 1. Build both halves -------------------------------------------------
log "1/6  building companion bundle"
COMPANION_TARBALL="$("$SELF_DIR/build-companion.sh")"     # builds + verifies relocatable + tars
log "2/6  building client wheel"
WHEEL="$("$SELF_DIR/build-client.sh")"

# --- 2. Sign, then re-pack so the asset carries the final signatures ------
log "3/6  signing distribution"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" "$SELF_DIR/sign.sh" "$NB_REPO_ROOT/Build/Distribution"
log "     re-packing $COMPANION_TARBALL with signatures"
COPYFILE_DISABLE=1 tar -czf "$COMPANION_TARBALL" -C "$NB_REPO_ROOT/Build/Distribution" .

# --- 3. Checksums + asset URLs -------------------------------------------
COMPANION_SHA="$(shasum -a 256 "$COMPANION_TARBALL" | awk '{print $1}')"
WHEEL_SHA="$(shasum -a 256 "$WHEEL" | awk '{print $1}')"
COMPANION_ASSET="$(basename "$COMPANION_TARBALL")"
WHEEL_ASSET="$(basename "$WHEEL")"
DL="https://github.com/$NB_REPO_SLUG/releases/download/$NB_TAG"
COMPANION_URL="$DL/$COMPANION_ASSET"
WHEEL_URL="$DL/$WHEEL_ASSET"
log "4/6  assets:"
log "       $COMPANION_ASSET  sha256=$COMPANION_SHA"
log "       $WHEEL_ASSET  sha256=$WHEEL_SHA"

render_formula() {
  sed -e "s|@@VERSION@@|$NB_VERSION|g" \
      -e "s|@@COMPANION_URL@@|$COMPANION_URL|g" \
      -e "s|@@COMPANION_SHA@@|$COMPANION_SHA|g" \
      -e "s|@@WHEEL_URL@@|$WHEEL_URL|g" \
      -e "s|@@WHEEL_SHA@@|$WHEEL_SHA|g" \
      "$SELF_DIR/formula/idb.rb.tmpl" > "$1"
}

NOTES="NB idb build.

- Version: \`$NB_VERSION\` (wheel: \`$FB_IDB_VERSION\`)
- Upstream commit: \`$BUILD_SHA\`
- Built with: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')
- Install: see release/RELEASING.md"

create_or_update_release() {  # args: <target-commitish>
  local target="$1"
  if gh release view "$NB_TAG" --repo "$NB_REPO_SLUG" >/dev/null 2>&1; then
    log "5/6  release $NB_TAG exists — uploading assets (clobber)"
    run gh release upload "$NB_TAG" --repo "$NB_REPO_SLUG" --clobber "$COMPANION_TARBALL" "$WHEEL"
  else
    log "5/6  creating release $NB_TAG at ${target:0:9}"
    run gh release create "$NB_TAG" --repo "$NB_REPO_SLUG" --target "$target" \
      --title "idb $NB_VERSION" --notes "$NOTES" "$COMPANION_TARBALL" "$WHEEL"
  fi
}

# Stage + commit + push <path> in <dir>, but only if it actually changed (so a
# re-run with an identical formula is a clean no-op, not an empty-commit error).
stage_and_commit() {  # args: <dir> <path> <message>
  local dir="$1" path="$2" msg="$3"
  if [[ "$NB_DRY_RUN" == "1" ]]; then
    run git -C "$dir" add "$path"
    run git -C "$dir" commit -m "$msg"
    run git -C "$dir" push   # never --force (repo rule)
    return 0
  fi
  git -C "$dir" add "$path"
  if git -C "$dir" diff --cached --quiet -- "$path"; then
    log "     $path unchanged — nothing to commit"
    return 0
  fi
  git -C "$dir" commit -m "$msg"
  git -C "$dir" push          # never --force (repo rule)
}

# --- 4/5/6. Publish per distribution mode --------------------------------
if [[ "$DISTRIB_MODE" == "tap" ]]; then
  # Tag the release at the pinned build commit; the formula lives in the tap repo.
  create_or_update_release "$BUILD_SHA"

  [[ -d "$NB_TAP_DIR" ]] || die "NB_TAP_DIR does not exist: $NB_TAP_DIR"
  mkdir -p "$NB_TAP_DIR/Formula"
  log "6/6  rendering formula into tap: $NB_TAP_DIR/Formula/idb.rb"
  render_formula "$NB_TAP_DIR/Formula/idb.rb"
  stage_and_commit "$NB_TAP_DIR" "Formula/idb.rb" "idb $NB_VERSION"
  log "done. Consumers:  brew tap ${NB_REPO_SLUG%/*}/nb && brew install ${NB_REPO_SLUG%/*}/nb/idb"

else  # url mode: formula committed to THIS fork at the tagged commit.
  log "6/6  rendering formula into fork: Formula/idb.rb"
  mkdir -p "$NB_REPO_ROOT/Formula"
  render_formula "$NB_REPO_ROOT/Formula/idb.rb"
  # Commit + push the formula, THEN tag the release at that commit so the raw
  # install URL (.../$NB_TAG/Formula/idb.rb) resolves to a commit containing it.
  stage_and_commit "$NB_REPO_ROOT" "Formula/idb.rb" "idb release $NB_VERSION"
  FORMULA_COMMIT="$(git rev-parse HEAD)"   # in dry-run this is the pre-commit HEAD
  create_or_update_release "$FORMULA_COMMIT"
  log "done. Consumers:  brew install https://raw.githubusercontent.com/$NB_REPO_SLUG/$NB_TAG/Formula/idb.rb"
fi

# --- Post-publish: confirm the asset URLs actually resolve ---------------
if [[ "$NB_DRY_RUN" != "1" ]]; then
  for u in "$COMPANION_URL" "$WHEEL_URL"; do
    code="$(curl -sIL -o /dev/null -w '%{http_code}' "$u" 2>/dev/null || echo 000)"
    case "$code" in
      200|302) log "     url ok ($code): $u";;
      *) log "     WARNING: $u returned $code — GitHub may have renamed the asset, or the fork is private (asset fetch needs a token). Verify the formula URLs by hand.";;
    esac
  done
fi
