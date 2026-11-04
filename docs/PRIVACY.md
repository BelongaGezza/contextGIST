# contextGIST — Privacy

**Status:** reviewed 2026-10-21 (claims corrected; see `docs/REVIEW_2026-10-21.md`). Sections 1-6 cover macOS only; section 7 covers Windows (no app yet). Describes what the shipped code
actually does today, following the format of GIST's `docs/PRIVACY.md`
(GIST commit 17154ea). Each claim cites the file that backs it, so it can
be re-verified against the source. Re-check this document whenever
`apps/macos/Sources/`, `contextGIST.entitlements`, `Info.plist`, or
`crates/contextgist-ffi` change.

contextGIST has no server, no accounts, no analytics, and no network
access. Everything below happens in memory on your Mac.

## 1. What contextGIST receives

Only the text you selected, and only when you choose **Speed Read with
contextGIST** from the Services menu. macOS hands that text to the app on a
pasteboard (`AppServiceProvider.readSelection`). contextGIST does not read
the clipboard at any other time, and it does not read the source document,
its file path, or anything else from the app you selected text in.

## 2. What contextGIST stores

**Nothing of your text.** contextGIST writes no files of its own; macOS creates a sandbox container (`~/Library/Containers/com.contextgist.macos`) and may keep window-frame state there. The selected text, and the word list made from it, exist only in
memory for as long as the popup window is open, and the app quits as soon
as that window closes. contextGIST doesn't explicitly wipe that memory; see
`docs/SECURITY_REVIEW.md` finding #2 for why. Closing the window drops the
last reference to them (`PopupController.windowWillClose` →
`AppServiceProvider`'s `popup = nil`). There is no library, history, cache,
settings file, or `UserDefaults` use: no code in `apps/macos/Sources/` or
`crates/contextgist-ffi/` writes to disk. (To check after a run:
`find ~/Library/Containers/com.contextgist.macos -type f`.)

## 3. What ever leaves your Mac

**Nothing.** The app runs in the macOS App Sandbox with no extra entitlements
(`apps/macos/contextGIST.entitlements`): no network client or server access,
and no access to user-selected or other files. The sandbox enforces this; it
isn't just a policy statement. contextGIST also never writes back to the
pasteboard or to the source document (`Info.plist` declares no
`NSReturnTypes`). This holds for a properly signed, sandboxed build. A build
signed with the `get-task-allow` entitlement (Xcode's default for development
signing) lets other processes of the same user read the app's memory; the
currently committed DMG is such a build (`docs/SECURITY_REVIEW.md` finding #5)
and should not be relied on for this guarantee until it is rebuilt.

## 4. Logging

contextGIST does not log the selected text or anything derived from it. The
app makes no `print`, `NSLog`, `os_log`, or `Logger` calls.

## 5. What macOS itself may do

Outside contextGIST's control, and standard for any Mac app:

- **If the app crashes while text is loaded, the crash report may contain
  some of that text.** macOS writes crash reports to
  `~/Library/Logs/DiagnosticReports`, and depending on your **System
  Settings → Privacy & Security → Analytics** choices, may share them with
  Apple and/or the developer. This is the one known path by which selected
  text could outlive the popup. contextGIST limits selections to 512 KB
  and catches errors in its text-processing code rather than crashing on
  them, but can't rule out every crash (`docs/SECURITY_REVIEW.md` finding
  #1). Review a contextGIST crash report before sharing it.
- The app you copied text from, and macOS's own Services machinery, handle
  the text before contextGIST receives it.
- While the popup is open, the current word is exposed to accessibility
  clients (screen readers, automation tools), and the popup window can be
  captured by screenshots or screen recording.
- Another program running as you can invoke the Service with its own text and
  open a popup. This cannot read your text, but the popup content should be
  treated as untrusted display text.

## 6. Third-party code

The only third-party code in the app is the Rust crates listed in
`docs/THIRD-PARTY.md` (text parsing, pacing, and the Swift↔Rust bridge).
None of the code reached from contextGIST's three exported functions
performs network or file I/O (checked by reading `gist-parse-txt`, `gist-rsvp`
and `gist-model`). The linked crate set includes crates capable of file I/O
(such as `tempfile`, `fs-err`) that those functions do not call; whether they
are dead-stripped from the binary is not verified. Some dependencies contain
`unsafe` code (for example `encoding_rs`). contextGIST's Rust surface
(`crates/contextgist-ffi/src/lib.rs`) is three pure functions with no I/O.

## 7. Windows (not shipped yet)

There is **no contextGIST Windows app yet**, so nothing in sections 1-6 has a
Windows counterpart to describe. What exists is a throwaway research tool
(`apps/windows/spikes/capture-prober`) and prototype packaging
(`tools/package-windows.ps1`, `tools/windows/`). This section records what
those do, and the commitments and known differences for the real app
(`docs/WINDOWS_PLAN.md` sections 4 and 7). Update it before the first release.

**The installer (prototype).** `install.cmd`/`install.ps1` run as the current
user and need no administrator rights. They write three things, and
`uninstall.ps1` removes exactly those:

1. the app folder, `%LOCALAPPDATA%\Programs\contextGIST`;
2. one Start menu shortcut, `contextGIST.lnk`;
3. one Apps & Features entry under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\contextGIST`.

No service, scheduled task, start-at-login entry or machine-wide setting is
created. The installer and uninstaller refuse to touch a folder that is not a
contextGIST install. The CI job `windows.yml` installs and uninstalls the
package and fails on any leftover.

**The capture spike.** It reads the text selected in another app with Windows
UI Automation to measure how reliably that works. It prints and logs metadata
only (process, control type, outcome, character count, timing) and never
prints or stores the selected text (`apps/windows/spikes/capture-prober/README.md`).
It is a measurement tool, not production code.

**Differences from macOS that the real app will have (disclose, do not hide):**

- **Not sandboxed.** Reading another process's selection needs a full-trust
  app (`runFullTrust`), so the macOS App Sandbox guarantee does not carry over
  (WINDOWS_PLAN W6). The app will have no network capability and
  `deny.toml` bans networking crates, but Windows will not enforce that.
- **A resident process is likely.** Windows has no Services-menu equivalent, so
  the app must fetch the selection itself, normally from a global hotkey. If it
  stays running between uses, "the process exits when the popup closes" no
  longer holds; the process model is still undecided (WINDOWS_PLAN section 3).
- **Reading the selection may switch on accessibility** inside Chromium and
  Electron apps while contextGIST queries them.
- **Crash dumps (Windows Error Reporting), the pagefile and hibernation** may
  hold selected text, as the macOS crash-report note in section 5 describes.
  They cannot be disabled per process without administrator-level settings.
- **The popup** exposes each word to accessibility clients and can be captured
  by screenshots or Windows Recall unless the window opts out of capture.
- **An install in your user profile can be replaced by any program running as
  you.** A packaged (MSIX) install avoids this; the zip installer does not
  (`docs/WINDOWS_INSTALL_OPTIONS.md`).
- **Unsigned builds.** SmartScreen will warn on a downloaded copy until a
  signing route is chosen. Verify the `SHA256SUMS` file for any download.
