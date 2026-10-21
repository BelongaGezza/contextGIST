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

Capture order: refuse password fields; UIA `TextPattern.GetSelection` on the
focused element and up to 3 parents; if the app exposes no TextPattern,
`EM_GETSEL` + `WM_GETTEXT` on a focused classic `Edit`/`RichEdit` control; one
retry after 300 ms when nothing usable came back (Chromium turns accessibility
on when a UIA client asks). Runs on a worker thread with a 2 s timeout.

Outcomes: `ok`, `empty`, `no_text_pattern`, `null_selection`, `password`,
`too_large` (over 512 KiB), `timeout`, `error:<hr>`. `via` is `uia` or
`win32edit`; `patterns` lists UIA patterns on the focused element
(`T` Text, `2` Text2, `V` Value). `first_attempt` is the outcome before the
retry/fallback.

`run-app-matrix-1.ps1` / `-2.ps1` drive Notepad, a WinForms RichTextBox, Edge,
Chrome, VS Code, Word and Windows Terminal on a dev machine (they open and
close their own sample windows and take over focus for about a minute; do not
type while they run).

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

Reading the table: `latency_ms` includes a deliberate 300 ms sleep before any
retry and a cold COM/UIA start, so the "~330 ms" figures are mostly that sleep,
not UIA cost. The Notepad row is classic Win32 Notepad (class `Edit`); the new
RichEdit-based Windows 11 Notepad has not been measured. No raw CSV is
committed yet.

## Known limitations (reviewed 2026-10-21; see `docs/REVIEW_2026-10-21.md`)

Do not use this code in production and fix these before collecting go/no-go
data: the `win32edit` path sizes its buffer from a target-supplied offset and
can panic or abort (S-02, Q-05); the cap compares UTF-16 bytes in the fallback
(Q-07); RichEdit offsets count CR once while `WM_GETTEXT` returns CRLF (Q-08);
class matching is case-sensitive (Q-09); multi-range selections have no
running cap (S-03); timed-out workers are never cancelled (S-14); CSV fields
are unquoted (S-13, Q-11); the scripts match windows by title and keep sending
keys if activation fails (S-13, Q-12).
