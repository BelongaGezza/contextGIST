# contextGIST — Privacy

**Status:** reviewed 2026-10-21 (claims corrected; see `docs/REVIEW_2026-10-21.md`). Covers macOS only. Describes what the shipped code
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
