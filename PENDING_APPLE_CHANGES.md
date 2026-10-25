# Pending Apple-side changes

Changes needed in `apps/macos/` (Swift, Xcode project, Info.plist, signing)
that were found in non-macOS sessions and must be made and verified on the
macOS machine (`CLAUDE.md` section 7). Findings referenced here are in
[`docs/REVIEW_2026-10-21.md`](docs/REVIEW_2026-10-21.md). Last updated
2026-10-25; delete an item when it lands and is verified on a Mac.

## Verified by hand on a Mac (2026-10-25, Release build of `main` at `b2bff15`, M1 Pro)

Services flow, popup playback and controls (Space, arrows, WPM slider, Esc),
pacing across sentence/clause/number tokens (Q-01), the over-512 KiB alert
(S-11) and the long-word fix (Q-15, PR #13) all passed by eye. The installed
Release app has no `get-task-allow` (S-01 build side). **Not exercised by hand:**
S-10 (`isRestorable`) and Q-17 (stale close callback); both are covered only by
code review and CI.

## Landed on a Mac (2026-10-22, branch `mac/parity-hardening`, 14 XCTests pass)

- Q-01: `tokenDurationMs` uses `Float`. Adopting `golden_extended.json` (copy
  in `apps/macos/Tests/`) also exposed a second divergence, fixed: `endsSentence`,
  `endsClause` and `isNumeral` now walk unicode scalars like Rust `char`s, so a
  token such as `x.` + combining acute is still a sentence end.
- Extended-golden tests: tokens, all-WPM durations under two configs, skip
  words, oversized-word chunk bytes. `setWpm` cases not yet covered.
- S-01 (build side): Release sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`
  (verified: no `get-task-allow`); `build-dmg.sh` refuses an app that has it.
  **The committed DMG in `dist/macos/` is still the old one: rebuild or retire it.**
- S-10 `isRestorable = false`; S-11 raw pasteboard size check; Q-17 stale
  close-callback guard.
- Q-15 (2026-10-25, PR #13): long words were truncated (`Pneumono…icros`);
  `WordDisplay` now scales the word to fit, keeping the focal letter centred.
  Verified by eye. Upstream GIST may have the same bug: BelongaGezza/gist#131.

## Other Apple-side items from the review (not yet started)

- Rebuild/retire the committed DMG (S-01, S-09); consider `sharingType = .none` (S-10);
  `release-sign.sh` entitlement gate.
- Monotonic clock instead of `Date()` (Q-14); weak self around `Task.sleep` (Q-21).
- RTL/CJK width maths (Q-16), a status result from
  `tokenize` instead of an empty list (Q-18; changes the uniffi signature).
- Portable `tools/upstream-review.sh` (Q-04) is shell, not Apple-specific, but
  `--record` should be verified on macOS after the change (BSD `sed` path).
