# Windows install options: zip, MSIX, winget

Comparison written 2026-11-04 from hands-on prototypes on Windows 11 x64
(10.0.26100) plus Microsoft Learn documentation. Payload is the capture-prober
spike (no Windows app exists yet). Follows `WINDOWS_PLAN.md` section 6 and the
tasks in [`INSTALL_TODO.md`](./INSTALL_TODO.md).

## What was built and tested

| Prototype | Command | Tested here |
|---|---|---|
| Zip + per-user `install.cmd`/`uninstall.cmd` | `tools/package-windows.ps1` | Built, installed, uninstalled (incl. the registered `UninstallString`), zero residue. Also in CI (`windows.yml`). |
| MSIX (`runFullTrust`) | `tools/package-windows-msix.ps1` | **Built** with `makeappx`; **signed** with a throwaway self-signed cert via `signtool` (cert deleted afterwards). **Not installed**: installing needs admin (below), which I did not use. |
| winget manifest (zip + nested portable) | `tools/windows/winget/` | `winget validate` passes. **Not installed**: local-manifest installs need `winget settings --enable LocalManifestFiles` (admin). URL and hash are placeholders. |
| Inno Setup / WiX | n/a | Not built (tool not installed). Row below is from documentation only. |

## Comparison

| | Zip + install.cmd (built) | MSIX | winget (zip + portable) | Inno Setup / WiX exe |
|---|---|---|---|---|
| One-click install | Unzip, double-click `install.cmd`. Two steps. | Double-click `.msix` (App Installer). One step, once trusted. | `winget install` (one command). | Double-click the exe. |
| Needs admin | No | Signed by a trusted cert: no. Unsigned: yes, all-users, dev-only (`-AllowUnsigned`; Learn: "don't use to distribute"). Self-signed: admin to trust it. | No (portable, per user). | Per-user mode: no. |
| Unsigned experience | SmartScreen "Run anyway" on the download. | **Not installable by normal users.** Signing is effectively mandatory outside the Store. | Hash-checked by winget; still subject to SmartScreen/validation checks on the zip. | SmartScreen "Run anyway". |
| Signing cost | Optional | Required: CA-trusted cert (Azure Artifact Signing about US$10/month if eligible, or OV cert), or Store (Microsoft signs free). | Optional | Recommended. |
| Uninstall | Settings > Apps, or `uninstall.cmd`. Removes folder, shortcut, `HKCU` key. Verified. | Settings > Apps. Windows removes everything; app state is virtualised, so removal is clean by design. | `winget uninstall`. Removes the extracted files and alias. | Settings > Apps (installer-defined). |
| Start menu / tray / start-at-login | Shortcut yes; others not in v1. | Yes (manifest-declared). | **No Start menu entry**; command alias only. | Yes. |
| Update path | Manual new download. | `.appinstaller` auto-update, Store, or winget. | `winget upgrade` once new versions are merged. | Own implementation. |
| Install location tamper risk (WINDOWS_PLAN s7) | `%LOCALAPPDATA%`: any same-user process can replace the exe. | `C:\Program Files\WindowsApps`: not writable by the app or user. **Fixes the risk.** | Per-user location, same as zip. | Per-machine = protected; per-user = same as zip. |
| Fits a hotkey/UIA app | Yes | Needs `runFullTrust` (restricted capability). Sideloading needs no approval; **Store needs a written justification** and acceptance is **(unverified)**. | Yes, but no auto-start/Start entry. | Yes. |
| Effort | Done | Moderate: manifest, real logos, cert, release job. | Small, but community-repo review and validation. | Moderate; new tool in the build. |

## Findings

1. **MSIX is the best end state but cannot be tried by users without a
   signing decision.** Unsigned MSIX needs admin and a special manifest OID;
   Learn says not to distribute that way. The signing route (Azure Artifact
   Signing, OV cert, or the Store, which re-signs for free) is the real
   blocker, as `WINDOWS_PLAN.md` section 6 already says.
2. **MSIX solves the install-location tamper risk** that the zip/per-user
   approach carries, because packaged files live in a protected location.
3. **winget is a discovery channel, not a packaging format.** Learn lists it
   as "adds discoverability to any distribution path". The simplest manifest
   (zip + portable) gives a command alias but no Start menu entry, so it suits
   a CLI tool better than a hotkey app. A better manifest points at the signed
   MSIX (or an installer) once one exists.
4. **Process model matters.** A launcher-per-invocation shell works well as a
   portable/zip; a resident tray app needs Start menu and possibly
   start-at-login, which favours MSIX or an installer.
5. **Store acceptance of a hotkey plus cross-process UIA app is
   unverified** (already flagged in the plan). Keep a non-Store path.

## Recommendation

1. **Now (no cost):** ship the zip + `install.cmd` from GitHub Releases with
   `SHA256SUMS`, documented SmartScreen steps. This is built and tested.
2. **Decide signing** (country/entity eligibility), then build the signed MSIX
   from the existing prototype and add a `windows-v*` release job.
   Self-signed MSIX is for the owner's own test machines only.
3. **Then add winget** pointing at the signed MSIX; use the zip + portable
   manifest only as a stopgap for command-line users.
4. **Only build an Inno Setup/WiX installer** if MSIX proves unworkable
   (e.g. Store or Defender rejects `runFullTrust` + UIA, or auto-start is
   required without packaging).

## Still to verify (needs admin or another machine)

- Install, run and uninstall the self-signed MSIX on a clean VM/Windows
  Sandbox with the cert trusted; confirm no residue and the WindowsApps path.
- `winget install --manifest` of the template, and the community-repo
  validation pipeline once a signed public URL exists.
- Real logos for the MSIX tiles (placeholders today).
- Whether the final shell needs a startup task (`desktop:StartupTask`) or
  tray registration in the manifest.
