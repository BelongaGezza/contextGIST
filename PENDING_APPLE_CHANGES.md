# Pending Apple-side changes

Changes needed in `apps/macos/` (Swift, Xcode project, Info.plist, signing)
that were found in non-macOS sessions and must be made and verified on the
macOS machine (`CLAUDE.md` section 7). Findings referenced here are in
[`docs/REVIEW_2026-10-21.md`](docs/REVIEW_2026-10-21.md). Last updated
2026-10-21; delete an item when it lands and is verified on a Mac.

## Done on a Mac (2026-10-22, branch `mac/parity-hardening`, 14 XCTests pass)

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
- Q-15 (2026-10-25): long words overflowed and were truncated (`Pneumono…icros`);
  `WordDisplay` now scales the word to fit, keeping the focal letter centred.
  Fix built and installed; by-eye re-check of the fix still to confirm.

## Other Apple-side items from the review (not yet started)

- Rebuild/retire the committed DMG (S-01, S-09); consider `sharingType = .none` (S-10);
  `release-sign.sh` entitlement gate.
- Monotonic clock instead of `Date()` (Q-14); weak self around `Task.sleep` (Q-21).
- RTL/CJK width maths (Q-16), a status result from
  `tokenize` instead of an empty list (Q-18; changes the uniffi signature).
- Portable `tools/upstream-review.sh` (Q-04) is shell, not Apple-specific, but
  `--record` should be verified on macOS after the change (BSD `sed` path).
