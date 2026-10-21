# Pending Apple-side changes

Changes needed in `apps/macos/` (Swift, Xcode project, Info.plist, signing)
that were found in non-macOS sessions and must be made and verified on the
macOS machine (`CLAUDE.md` section 7). Findings referenced here are in
[`docs/REVIEW_2026-10-21.md`](docs/REVIEW_2026-10-21.md). Last updated
2026-10-21; delete an item when it lands and is verified on a Mac.

## Parity with the Rust core (core side merged in PR #6)

The Rust core enforces the 512 KiB cap, parses as UTF-8 only, and returns word
tokens split at 256 bytes. The exported uniffi surface is unchanged, so the
generated Swift bindings are unchanged. `apps/macos/Tests/golden.json` is
unchanged and still passes. To do on a Mac:

1. **`tokenDurationMs` must use `Float`, not `Double`** (`RsvpView.swift`,
   Q-01). Rust computes `((base_ms as f32) * mult).round()`. With `Double`, the
   1.3 clause pause differs by 1 ms at some WPMs (e.g. 110: Rust 709, Swift 708).
   Use `UInt64((Float(baseMs) * multiplier).rounded())` with `multiplier: Float`.
2. **Adopt `crates/contextgist-ffi/testdata/golden_extended.json`** in
   `Tests/PacingParityTests.swift` (copy it into the test bundle or read it by
   path). It covers every integer WPM 100-1000 under two configs, Unicode
   punctuation tokens, oversized-word chunk lengths, `skip_words` and `set_wpm`
   results. Step 1 makes the duration checks pass; they fail before it.
3. **Check long words** now arrive as <=256-byte tokens: confirm the popup
   renders them sensibly (Q-15 scales/clips very long words).
4. Run `./tools/gen-bindings.sh && cd apps/macos && xcodegen generate &&
   xcodebuild test -scheme contextGIST` and confirm the generated bindings have
   no diff against the previous output.

## Other Apple-side items from the review (not yet started)

- Release build without `get-task-allow` (S-01): `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`
  for Release, a gate in `build-dmg.sh`/`release-sign.sh` that fails when the
  entitlement is present, then rebuild or retire the committed DMG.
- `NSWindow.isRestorable = false`, consider `sharingType = .none` (S-10).
- Pasteboard length check before string conversion (S-11).
- `popup === controller` guard in `onClose` (Q-17).
- Monotonic clock instead of `Date()` (Q-14); weak self around `Task.sleep` (Q-21).
- Long-word scaling (Q-15), RTL/CJK width maths (Q-16), a status result from
  `tokenize` instead of an empty list (Q-18; changes the uniffi signature).
- Portable `tools/upstream-review.sh` (Q-04) is shell, not Apple-specific, but
  `--record` should be verified on macOS after the change (BSD `sed` path).
