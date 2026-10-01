# contextGIST

A macOS Services-menu item that speed-reads whatever text you've selected,
anywhere. Select text in Word, Preview, Safari, TextEdit, or any other app
that supports Services, choose **Speed Read with contextGIST** from the
right-click/Services menu, and a small popup window displays it RSVP-style
("rapid serial visual presentation") — one word at a time, paced, with
play/pause/rewind/fast-forward/speed controls. Close the window and the
text is gone — contextGIST has no library, no persistence, and no account
system.

This is a narrow fork of [GIST](https://github.com/BelongaGezza/gist)'s core reading experience: its
RSVP pacing engine and tokenizer, reused as-is, with none of GIST's
library/storage/search/encryption machinery. See
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for how the two projects
relate, and [`CLAUDE.md`](./CLAUDE.md) for build/dev commands.

## Status

Early scaffolding — not yet built and run end-to-end. See `CLAUDE.md` for
current state.

## Building

Requirements: Rust (version pinned in `rust-toolchain.toml`), Xcode, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). A clone of the
[GIST repo](https://github.com/BelongaGezza/gist) must sit next to this one at `~/develop/reader`
(`git clone git@github.com:BelongaGezza/gist.git ../reader`), since `crates/contextgist-ffi` depends on its
crates via relative path.

```bash
# Rust workspace
cargo test --workspace

# macOS app
./tools/gen-bindings.sh                   # regenerate Swift FFI bindings
cd apps/macos && xcodegen generate        # generate the Xcode project (never committed)
xcodebuild -scheme contextGIST build
```

## License

MIT — see [`LICENSE`](./LICENSE).
