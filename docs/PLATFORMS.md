# Platforms: parallel development and release

How macOS, Windows 11 and Linux (and later iOS/iPadOS and Chrome) are
developed and released independently. Strategy and ordering rationale live in
[`DEVELOPMENT_PLAN.md`](./DEVELOPMENT_PLAN.md); this doc is the working
contract and the per-platform TODOs.

## Layout

```
crates/                    shared Rust core (one place; never forked per platform)
apps/{macos,windows,linux} one app per platform, each owning its own folder
tools/package-<platform>.* one packaging script per platform
dist/{macos,windows,linux} that platform's final installer + INSTALL.txt
```

## Rules for working in parallel

1. **Stay in your lane.** A platform branch touches its own `apps/<platform>/`,
   `tools/package-<platform>.*`, `dist/<platform>/`, its section in this doc and
   its CI job. Shared files (`crates/`, root `Cargo.toml`, `UPSTREAM_BASELINE`,
   `docs/ARCHITECTURE.md`) change in small separate PRs that every platform
   rebases on.
2. **Pacing and tokenizing live in one place.** Swift's pacing math must use
   `Float`, matching Rust's `f32` (not yet true: Q-01, `PENDING_APPLE_CHANGES.md`).
   Never hand-port pacing logic
   again (see `DEVELOPMENT_PLAN.md`, "Guiding constraint"). New platforms consume
   the shared core and must pass the golden parity tests.
3. **Branches and releases.** Branch `platform/<name>/<topic>`; merge to `main`
   via PR with that platform's CI job green. Tag releases per platform:
   `macos-vX.Y.Z`, `windows-vX.Y.Z`, `linux-vX.Y.Z`. A release of one platform
   never waits on another.
4. **Upstream review is shared.** `tools/upstream-review.sh --record` moves the
   one GIST pin for every platform; run the other platforms' tests before
   recording it. Until the script is made portable (Q-04: BSD `sed -i ''`),
   only macOS can run `--record`; the report mode runs anywhere with `bash` and
   `git`. CI asserts `UPSTREAM_BASELINE` equals the `Cargo.toml` rev.
5. **Disclosures stay true per platform.** `docs/PRIVACY.md` and
   `docs/THIRD-PARTY.md` must describe each shipped platform; any platform that
   can't match the security baseline (sandboxed, no network, no telemetry, no
   text logging, input-only) discloses the gap.

## Status

| Platform | Code | CI | Package script | Signed release |
|----------|------|----|----------------|----------------|
| macOS | yes | yes (`ci.yml`) | `tools/package-macos.sh` | no (unsigned; blocked on an Apple Developer account) |
| Windows 11 | spike only (`apps/windows/spikes/capture-prober`; no app) | yes (`windows.yml`: fmt, clippy, tests, spike build) | no | no |
| Linux | no | shared core runs on ubuntu in `ci.yml`; no Linux app job | no | no |

## TODO: shared (unblocks Windows and Linux; do first)

- [x] (2026-10-22) Extract `crates/contextgist-core`: plain Rust (no uniffi) exposing
  `tokenize`, `default_config`, `orp_index`; make `contextgist-ffi` a thin uniffi
  wrapper over it. The Windows/Linux Rust shells depend on it directly.
- [ ] Desktop Rust shells (Windows, Linux) drive `gist_rsvp::RsvpSession`
  directly instead of porting `PacingEngine`; golden-test against `golden.json`
  (macOS keeps its Swift engine, guarded by the parity tests).
- [ ] **Parity hardening, Swift half** (`REVIEW_2026-10-21.md`; the Rust half is
  done and merged in PR #6: extended golden for T1-T4 and T6-T9, 256-byte split,
  512 KiB cap, UTF-8-only parse). Pending a macOS session: Swift durations use
  `Float` (Q-01) and the extended golden is adopted. Tests T5, T10, T11, T13, T14
  are not written.
- [x] CI: `ci.yml` (ubuntu + macOS) and the path-filtered `windows.yml`
  (`windows-latest`) both run fmt, clippy and `cargo test --workspace --locked`
  (PRs #3, #8). Still open: an always-run aggregator check and branch protection
  before any path-filtered job is made required (Q-19).
- [ ] (Optional while there is one maintainer) Add `.github/CODEOWNERS` mapping each `apps/<platform>/`, `dist/<platform>/`
  and `tools/package-<platform>.*` to its maintainer.
- [ ] Per-platform release workflow triggered by `windows-v*` / `linux-v*` tags
  (mirror what macOS does locally in `tools/release-sign.sh`).
- [ ] Decide DMG/installer storage: committed binaries (current for macOS) vs
  Git LFS vs GitHub Releases, before Windows/Linux installers add more weight.
  `WINDOWS_PLAN.md` section 6 and the 2026-10-21 review (S-01, S-09, Q-25)
  both favour GitHub Releases with a published SHA-256.

## TODO: Windows 11

Rationale, phases and numeric exit criteria: [`WINDOWS_PLAN.md`](./WINDOWS_PLAN.md).
v1 = hotkey + UI Automation capture + manual paste, x64, direct download.

- [x] **W0** `.gitattributes` (#1), `windows-latest` CI (#3) and fmt/clippy/spike-build gates (#8) merged 2026-10-21.
- [ ] **W0.5** Capture spike: console prober over ~15 apps, numeric go/no-go. Prober built (#4) and hardened on `platform/windows/spike-fixes` (review fixes, CSV schema v2, `run-app-matrix.ps1`); still to do: run the matrix, commit the raw CSVs, apply the go/no-go.
- [ ] **W1** Read GIST's Windows stack (ADR-015/017/018, bindgen security review),
  then a three-way shell spike (native Rust / WinUI 3 + uniffi-cs / minimal Win32).
  Decide the process model (launcher-per-invocation vs resident). Write the
  Windows section of `PRIVACY.md` before coding.
- [x] **W2** `contextgist-core` extraction (done 2026-10-22; generated Swift bindings byte-identical) with a shared `skip_words` helper and
  oversized-token golden cases; keep Swift/golden paths unchanged until a macOS session.
- [ ] **W3** `apps/windows`: popup, `RegisterHotKey`, UIA capture (password refusal,
  512 KiB cap, worker thread + timeout), manual paste, per-failure messages.
- [ ] **W4** `tools/package-windows.ps1`, `dist/windows/`, `INSTALL.txt`,
  `WINDOWS_GUIDE.md`, `THIRD-PARTY.md`, Windows security pass, update path.
- [ ] **W5** First release `windows-vX.Y.Z` (signing per owner eligibility).
- [ ] Post-v1, separate releases: Share Target, opt-in Ctrl+C, ARM64, MSIX/Store,
  start-at-login, hotkey rebinding UI.
- [ ] `// TODO(test): verify on [PLATFORM: Windows/ARM64]` when ARM64 work starts.

## TODO: Linux

- [ ] Spike first (time-boxed): X11 PRIMARY selection via global shortcut;
  Wayland primary-selection support per compositor; Flatpak portal limits.
  Record findings in `docs/ARCHITECTURE.md` before building.
- [ ] Scaffold `apps/linux`, reusing whichever Rust-side pieces the Windows shell spike keeps.
- [ ] Entry point per spike outcome; document unsupported desktops.
- [ ] Reject oversized selections and discard text on close.
- [ ] Golden parity tests against `apps/macos/Tests/golden.json`.
- [ ] Flatpak packaging (sandboxed, no network); write `tools/package-linux.sh`
  to populate `dist/linux/`; AppImage as an optional second target.
- [ ] `dist/linux/INSTALL.txt` (including how to bind the shortcut).
- [ ] Add Linux to `docs/PRIVACY.md`, `docs/THIRD-PARTY.md` and a security-baseline pass.
- [ ] Linux section in the README and a `docs/LINUX_GUIDE.md`.

## TODO: macOS (remaining)

- [ ] Rebuild the DMG without `get-task-allow` (S-01) and apply the Swift items
  in `PENDING_APPLE_CHANGES.md`.
- [ ] Developer ID signing and notarization via `tools/release-sign.sh`
  (`SECURITY_REVIEW.md` finding #3, blocked on an Apple Developer account);
  then publish the notarized DMG.
- [ ] Tag `macos-vX.Y.Z` releases once the above is done.
