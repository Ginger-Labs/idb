# Releasing the NB idb build

Local (no-CI) build + GitHub-release pipeline for this fork of `facebook/idb`. One
release ships **both halves in lockstep** — the `idb_companion` macOS binary and the
`fb-idb` Python client — and a Homebrew formula that installs them together.

> Naming: everything is **Notability / NB**. The `ginger-labs/` in `brew` commands is
> just the GitHub org slug.

---

## What gets built

| Asset | From | Notes |
|---|---|---|
| `idb_companion-<version>-arm64.tar.gz` | `./build.sh build` → `Build/Distribution/` | self-contained, relocatable; arm64-only (see Limitations) |
| `fb_idb-<version>-py3-none-any.whl` | `setup.py` (regenerates gRPC stubs) | pure Python; needs python@3.12 |
| `idb.rb` | `release/formula/idb.rb.tmpl` | one formula, both halves |

### Version scheme (single source: `release/version.sh`)
- `NB_VERSION = 1.1.8-nb-<short-sha>` — used **everywhere**: git tag (`v$NB_VERSION`),
  GitHub release, asset filenames, brew formula, `idb_companion --version`.
- `FB_IDB_VERSION = 1.1.8+nb.<short-sha>` — the **wheel only**. PEP 440 cannot encode a
  hex build id except as a `+local` segment; setuptools rejects the hyphen form. pip
  therefore reports the client as `1.1.8+nb.<sha>`. This is the one place `+` survives.

Bump the marketing base (`1.1.8`) in `release/version.sh`.

---

## This release was built against

- **Pinned upstream commit:** `5366f83fe` — committed **2026-06-26**
  (≥ 2026-06-15, so it includes the DTUHID transport + the pinch/multitap gesture work).
- **Xcode:** 26.3 (build 17C529) — the companion is coupled to this Xcode's
  CoreSimulator. Rebuild when the team bumps Xcode major; record the new version here.
- **Host:** Apple Silicon (arm64), macOS 15 (Darwin 25.x).

---

## Prerequisites (one-time, H6)

```sh
brew install xcodegen protobuf swift-protobuf python@3.12 gh
gh auth login          # authenticate to the Ginger-Labs org
```

`./build.sh` clones + builds `protoc-gen-grpc-swift` (grpc-swift 1.23.1) into `Build/`
on first run. `xcpretty` is optional (build falls back to raw `xcodebuild`).

---

## Fork patches (required — already committed on the `nb` branch)

The OSS tree at the pinned commit does **not** build a working release as-is; these
minimal, behavior-preserving patches are required and must ride along on any re-pin:

1. **`idb/common/types.py`** — `StrEnum310` was imported from Meta-internal
   `python.migrations.py310` (absent from OSS → `import idb` fails). Aliased to stdlib
   `enum.StrEnum` (identical on python@3.12).
2. **`setup.py`** — added `pyre-extensions` to `install_requires` (used by
   `idb/common/plugin.py`; Meta's Buck supplied it out of band, so `pip install` left
   the client broken).
3. **`idb_companion/project.yml` + `idb_companion/main.swift`** — the NB version stamp:
   `BuildInfo.swift` gets `kVersion` from `$NB_COMPANION_VERSION`, surfaced in
   `idb_companion --version` (which otherwise reports only build date/time).

The next three are **Xcode 26.3 build fixes** — the pinned commit was authored against
Xcode 27 beta and does not compile cleanly on 26.3 without them:

4. **`FBControlCore/Management/FBiOSTarget.swift` + `.h`** — `FBiOSTargetTypeStringFromTargetType`
   was `@_cdecl … -> NSString`; on Xcode 26.3 its bridged return (`Optional<NSString>` vs the
   header's `NSString`) crashed the mandatory SIL linker when `idb_companion` linked it. It has
   no C/ObjC callers, so it is now a plain Swift `-> String` and the C export is dropped
   (behavior-preserving).
5. **`idb_companion/project.yml`** — added a `CompanionDiscovery` static-framework target and
   wired `idb-repl` to it. `idb-repl` (which `import`s `CompanionDiscovery`) was already broken
   on upstream `nb`; it was just never reached before the build got this far.
6. **`build.sh`** — generate the proto *before* generating projects (else `IDBGRPCSwift` is
   generated with empty sources and emits no module); build `IDBGRPCSwift`/`CompanionDiscovery`
   as their own schemes (Xcode 26 only installs a staticlib framework's `.swiftmodule` when it is
   the primary build target); and only strip xattrs when the filesystem lacks them.

Verified on Xcode 26.3: a clean `./build.sh build` succeeds, `build-companion.sh`'s relocation
proof passes (runs `--version` from a different path), and `smoke-test.sh` passes
(`idb ui describe-all` + `idb ui pinch` on a booted simulator).

Build-env detail (not a source patch): `release/build-client.sh` pins `setuptools<81`
in its build venv because the proto-gen plugin (`protoc_compiler_template.py`) imports
`pkg_resources`, removed in setuptools 81+.

---

## Distribution mode — use `tap`

**`url` mode does not work on current Homebrew.** Modern brew (≥ ~5.x) rejects
installing a formula from a URL *or* a local file — `brew install <url>` and
`brew install ./idb.rb` both fail with "Homebrew requires formulae to be in a tap."
So the only viable consumer path is a **tap**:

- **`tap`** (required): formula in a separate `Ginger-Labs/homebrew-nb` repo. Install
  `brew install ginger-labs/nb/idb`; `brew upgrade` tracking works. Needs the tap repo
  created + cloned locally (export `NB_TAP_DIR`).

`release.sh` still has a `url` branch (it commits `Formula/idb.rb` into the fork), but
the resulting formula is **not consumer-installable** on modern brew — treat `url` as
deprecated/publish-only. Both modes ship identical assets + formula body.

---

## Run a release (H7)

Commit any fork patches first (the orchestrator refuses a dirty tree — the version SHA
must represent exactly what is built).

```sh
# tap mode
DISTRIB_MODE=tap NB_TAP_DIR=/path/to/homebrew-nb \
  CODESIGN_IDENTITY=- ./release/release.sh

# url mode
DISTRIB_MODE=url CODESIGN_IDENTITY=- ./release/release.sh
```

Add `NB_DRY_RUN=1` to do everything local (build, sign, render the formula) while
skipping every outward-facing action (GitHub release, git commit/push/tag).

What it does, idempotently: `version.sh` → `build-companion.sh` → `build-client.sh` →
`sign.sh` → re-tar (so the asset carries signatures) → `shasum` → create/clobber the
GitHub release on this fork → render the formula → publish per mode (tap: commit+push
in `NB_TAP_DIR`; url: commit+push `Formula/idb.rb` in the fork, then tag at that commit).
**Never force-pushes.**

### The individual scripts (each standalone)
| Script | Does | Verifiable now |
|---|---|---|
| `version.sh` | prints/export version vars | ✅ |
| `build-companion.sh` | builds, asserts relocatability (otool), tars, proves extraction | needs Xcode prereqs |
| `build-client.sh` | builds + verifies the wheel (`idb ui pinch --help`) | ✅ (no Xcode needed) |
| `sign.sh [dist]` | signs inner→outer, verifies | ✅ (ad-hoc path) |
| `smoke-test.sh [--udid …]` | boots a sim, asserts `--version` / `ui describe-all` / `ui pinch` | needs a built companion + sim |
| `release.sh` | the orchestrator above | H7 |

---

## Signing (H5)

Default is **ad-hoc** (`CODESIGN_IDENTITY=-`) — the minimum to execute on Apple Silicon,
fine for internal use. For Gatekeeper-friendly distribution:

```sh
CODESIGN_IDENTITY="Developer ID Application: …" \
NB_NOTARIZE=1 NB_NOTARY_PROFILE=<notarytool-keychain-profile> \
DISTRIB_MODE=… ./release/release.sh
```

`sign.sh` then adds hardened runtime + a secure timestamp and submits to notarytool.
(A bare CLI/tarball can't be stapled; Gatekeeper validates the ticket online.)

---

## Consumer install

```sh
brew tap ginger-labs/nb
brew install ginger-labs/nb/idb
```

**Migration (H8):**
- If `fb-idb` was installed via pip, remove it first so its `idb` doesn't shadow the
  brew one: `pip3 uninstall fb-idb` (the distribution is `fb-idb`, not `idb`).
- If the upstream companion is installed, remove it — it collides on the
  `idb_companion` binary name: `brew uninstall facebook/fb/idb-companion`.
- Merely having the `facebook/fb` tap (without installing) is fine now that the formula
  no longer declares `conflicts_with` (which modern brew refused to resolve against that
  untrusted tap).

**Command Line Tools:** the formula is **not bottled**, so brew installs it via its
"from source" path and requires an up-to-date toolchain. On a machine with full Xcode
selected (`xcode-select -p` → `…/Xcode.app`), a stale standalone CLT can still make brew
error with *"A newer Command Line Tools release is available."* Fix by updating CLT
(System Settings → Software Update) or removing the stale standalone copy
(`sudo rm -rf /Library/Developer/CommandLineTools`; Xcode still provides the toolchain).

Verify: `idb_companion --version` shows the NB version; `idb ui pinch --help` works.

---

## Re-pinning to a newer upstream commit

```sh
git fetch upstream
# Choose a known-green SHA ≥ 2026-06-15 (HEAD is mid Swift-migration; not every SHA
# builds). Rebase/cherry-pick the nb branch (incl. the fork patches above) onto it.
git rebase --onto <new-sha> <old-sha> nb     # or cherry-pick the patches

./build.sh build && ./release/smoke-test.sh  # confirm a clean build + working binaries
DISTRIB_MODE=… ./release/release.sh
```

`version.sh` picks up the new short SHA automatically, so the new release is uniquely
versioned.

---

## Limitations / watch-items

- **arm64 only.** `build.sh` hard-codes `ARCHS=arm64` in `invoke_xcodebuild`. Universal
  (`ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`) requires editing that setting in
  `build.sh` — it can't be overridden by env. The asset is labeled by the binary's
  actual archs (`lipo`), so it self-updates if you do.
- **Xcode coupling.** The companion loads Apple private frameworks (CoreSimulator, …)
  from the active Xcode at runtime. Rebuild on Xcode major bumps.
- **Private fork (H4).** If the fork/release is private, every engineer needs
  `HOMEBREW_GITHUB_API_TOKEN` to download release assets. Public fork (MIT source) ⇒
  frictionless install. `release.sh` warns if an asset URL doesn't resolve.
- **Relocatable bundle.** `build-companion.sh` asserts no build-tree paths leaked into
  the binary and proves it runs from a different path — but verify on a genuinely clean
  machine before declaring "one command."
