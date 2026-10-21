# capture-prober (W0.5 capture spike)

Throwaway console tool that measures how reliably another app's text selection
can be read on Windows, using the same steps as the planned v1 capture path
(`docs/WINDOWS_PLAN.md` section 4). It is **not** part of the root Cargo
workspace (own `[workspace]` table), so it never touches the root `Cargo.lock`
or the macOS/Linux CI.

**Privacy:** it prints and logs metadata only (process, control type, outcome,
character count, latency). It never prints or stores the selected text.

## Run

```
cd apps/windows/spikes/capture-prober
cargo run -- --csv results.csv        # select text elsewhere, press Ctrl+Alt+R
cargo run -- --after 5 --csv r.csv    # capture once after 5 s, then exit
```

Options: `--csv FILE` (schema v2, refuses a file whose header differs),
`--label NAME`, `--trial N`, `--app-version V`, `--expect-exe NAME` (records
`wrong_target` if the focused element belongs to another process),
`--retry-ms MS` (default 300). Each CSV row carries label, trial, Unix time,
OS build, app version, exe, class, control type, patterns, `init_ms`,
`t_first_ms`, `t_total_ms`, `retry_used` and `first_attempt`, so first-attempt
latency is separate from the retry sleep.

Capture order: refuse password fields; UIA `TextPattern.GetSelection` on the
focused element and up to 3 parents; if the app exposes no TextPattern, a
classic `Edit`/`RichEdit` fallback (`EM_GETSEL`/`WM_GETTEXT` for `Edit`,
`EM_GETSELTEXT` for RichEdit, with the range and text length bounded before any
allocation); one retry after the retry delay when nothing usable came back
(Chromium turns accessibility on when a UIA client asks). Runs on a supervised
worker thread with a 2 s timeout; a press while a previous capture is stuck
reports `busy` instead of leaking another thread.

Outcomes: `ok`, `empty`, `no_text_pattern`, `null_selection`, `password`,
`too_large` (over 512 KiB UTF-8, or more than 1000 ranges), `wrong_target`,
`busy`, `timeout`, `error:<detail>` (a panic is `error:panic`). `via` is `uia`
or `win32edit`; `patterns` lists UIA patterns on the focused element (`T` Text,
`2` Text2, `V` Value).

`run-app-matrix.ps1` drives Notepad, an over-cap Notepad, a WinForms
RichTextBox, Edge (page, over-cap, password field), Chrome, VS Code, Word and
Windows Terminal on a dev machine, with multi-line CRLF, CJK, RTL and emoji
samples. It opens its own `cgprobe-` windows, uses throwaway browser profiles,
activates by PID and skips a trial rather than send keys when activation
fails. It takes over focus for several minutes; do not type while it runs.
Not covered by the script (run by hand with `--label`): an elevated app,
Firefox, Acrobat / Edge PDF, Slack/Teams, conhost, a suspended-process hang.

## Interim observations (2026-10-21, one Windows 11 x64 machine, single trial each, hand-recorded)

| App | Focused control | Patterns | Result | Notes |
|-----|-----------------|----------|--------|-------|
| Notepad (classic) | Win32 `Edit` | Value only | **ok via `win32edit`**; UIA alone: `no_text_pattern` | A UIA-only design would miss Notepad |
| WinForms RichTextBox | `RICHEDIT50W` | Text, Text2, Value | ok via UIA, 28 ms | |
| Edge (page) | Document | Text, Value | ok via UIA, ~22 ms | |
| Edge (password field) | Edit | Text, Value | `password` (refused) | privacy rule works |
| Chrome (page) | first call: Pane; then Document | none, then Text+Value | first attempt `no_text_pattern`, **ok after retry** (~330 ms); later calls ok in ~21 ms | confirms the retry rule |
| VS Code (Electron) | `native-edit-context` | Text, Value | **empty** both trials | Select-all via Ctrl+A returned an empty range. Needs manual confirmation (focus vs real limitation) |
| Word | Document | Text2 | ok via UIA, 53 ms | |
| Windows Terminal | `TermControl` | Text | ok via UIA, 27 ms (select-all via Ctrl+Shift+A) | |

Not yet run: Firefox, Acrobat / Edge PDF, Slack/Teams, conhost, an elevated
app, and the repeated trials (at least 60 per core app) the go/no-go in
`docs/WINDOWS_PLAN.md` section 8 requires. **This is not yet a go/no-go.**

Reading the table: these are the pre-rewrite observations. `latency_ms` then
included a deliberate 300 ms sleep before any retry and a cold COM/UIA start, so
the "~330 ms" figures are mostly that sleep, not UIA cost (schema v2 separates
them). The Notepad row is classic Win32 Notepad (class `Edit`); the new
RichEdit-based Windows 11 Notepad has not been measured. No raw CSV is
committed yet.

## Status of the 2026-10-21 review findings (`docs/REVIEW_2026-10-21.md`)

Addressed in code on `platform/windows/spike-fixes` (unit-tested helpers;
`cargo fmt`, `clippy -D warnings` and 9 tests pass): bounded buffers and
`.get()` slicing (S-02, Q-05), running UTF-8 cap and range cap (S-03, Q-07),
case-insensitive exact class match and RichEdit `EM_GETSELTEXT` (Q-08, Q-09),
single-flight capture (S-14), `catch_unwind` reported as `error:panic` (Q-05),
quoted and sanitised CSV with I/O errors checked and a schema version
(S-13, Q-11), richer metadata (Q-06, Q-10), PID-based matrix script (S-13,
Q-12).

Still open: none of this has been exercised against the live app matrix since
the rewrite; no raw CSV is committed; the rewritten matrix script has not been run
(verified here only by reading it); the selection `String` is dropped, not zeroed; there is no
cancellation of a hung UIA call (the worker is abandoned); the sample set lacks
Firefox, PDF viewers, Slack/Teams, conhost, an elevated app and the new Windows
11 Notepad. **Do not use this code in production**: it is a measurement tool.
