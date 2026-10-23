//! Platform-neutral contextGIST core: selection text in, token stream and
//! pacing helpers out. Plain Rust (no uniffi), so desktop shells (Windows,
//! Linux) depend on it directly and `contextgist-ffi` is only a thin uniffi
//! wrapper over it. Tokenizing and pacing come from the pinned GIST crates;
//! nothing here may fork their logic (docs/ARCHITECTURE.md).

pub use gist_model::{Token, TokenKind};
pub use gist_rsvp::Config;

// `contain` relies on `catch_unwind`, which does nothing under `panic = "abort"`
// (the panic would then abort the process and write a crash report that can
// contain the selection). Fail the build instead of silently losing that.
#[cfg(panic = "abort")]
compile_error!("contextgist-core requires panic = \"unwind\" (see `contain`)");

/// Largest selection (UTF-8 bytes) `tokenize` accepts; larger input yields no
/// tokens. Same limit the macOS shell enforces (`maxSelectionBytes`), enforced
/// here too so every platform shell inherits it.
pub const MAX_SELECTION_BYTES: usize = 512 * 1024;

// ── Panic containment ────────────────────────────────────────────────────────

/// Runs `f`, turning a panic into `fallback` instead of letting it escape the
/// caller. A crash writes a report while the selection is in memory
/// (docs/SECURITY_REVIEW.md finding #1), so shells degrade to an empty or
/// neutral result instead.
///
/// Does not touch the panic hook: call [`silence_panic_messages`] once at
/// startup in a shipping binary (not under `cargo test`, where it would
/// swallow assertion messages).
pub fn contain<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    std::panic::catch_unwind(f).unwrap_or(fallback)
}

/// Installs a panic hook that prints nothing, once per process. Rust's default
/// hook writes the panic message to stderr, and some std panic messages quote
/// the string being operated on (e.g. `str` slicing's "byte index N is not a
/// char boundary ... of `<text>`"), which would put selected text somewhere it
/// could be captured.
pub fn silence_panic_messages() {
    static SILENCE_PANICS: std::sync::Once = std::sync::Once::new();
    SILENCE_PANICS.call_once(|| std::panic::set_hook(Box::new(|_| {})));
}

// ── Tokenizing ───────────────────────────────────────────────────────────────

/// Tokenize `text` with the upstream crates, without panic containment.
///
/// - Input over [`MAX_SELECTION_BYTES`] yields no tokens (checked before any
///   parsing).
/// - Parsed as UTF-8 only. `Auto` encoding detection would reinterpret a
///   NUL-heavy selection as UTF-16 and show different text than was selected.
///   (A leading U+FEFF is dropped, as for a BOM.)
/// - Word tokens over `gist_rsvp::MAX_TOKEN_BYTES` (256) are split exactly as
///   `RsvpSession::new` splits them, so every shell sees the same token
///   indices that `RsvpSession` uses.
pub fn tokenize(text: &str) -> Vec<Token> {
    if text.len() > MAX_SELECTION_BYTES {
        return Vec::new();
    }
    let limits = gist_model::ParseLimits {
        max_bytes: MAX_SELECTION_BYTES,
        ..gist_model::ParseLimits::default()
    };
    match gist_parse_txt::parse_with_encoding(
        text.as_bytes(),
        "selection",
        &limits,
        gist_parse_txt::EncodingChoice::Named("utf-8"),
    ) {
        Ok(parsed) => {
            gist_rsvp::RsvpSession::new(parsed.document.token_stream, gist_rsvp::Config::default())
                .tokens
        }
        Err(_) => Vec::new(),
    }
}

/// Index of the token `n` *words* away from `from` in direction `forward`
/// (paragraph/section breaks are stepped over but not counted), clamped to
/// the token range. Mirrors `gist_rsvp::RsvpSession::back_words` and the
/// Swift `skipWords` (which adds the forward direction).
pub fn skip_words(tokens: &[gist_model::Token], from: usize, n: usize, forward: bool) -> usize {
    let last = tokens.len().saturating_sub(1);
    let mut target = from.min(last);
    let mut skipped = 0;
    while skipped < n {
        let next = if forward {
            if target >= last {
                break;
            }
            target + 1
        } else {
            if target == 0 {
                break;
            }
            target - 1
        };
        target = next;
        if tokens[target].kind == gist_model::TokenKind::Word {
            skipped += 1;
        }
    }
    target
}

/// GIST's default pacing config (250 WPM, etc — see `gist_rsvp::Config::default`).
pub fn default_config() -> Config {
    Config::default()
}

/// Byte offset of a word's Optimal Recognition Point. See `gist_rsvp::orp_index`.
pub fn orp_index(word: &str) -> usize {
    gist_rsvp::orp_index(word)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_caps_and_splits() {
        assert!(tokenize(&"x ".repeat(MAX_SELECTION_BYTES)).is_empty());
        let t = tokenize(&"x".repeat(300));
        assert_eq!(t.len(), 2);
        assert_eq!((t[0].text.len(), t[1].text.len()), (256, 44));
    }

    #[test]
    fn contain_returns_the_fallback_on_panic() {
        assert_eq!(contain(7, || -> i32 { panic!("boom") }), 7);
        assert_eq!(contain(7, || 1), 1);
    }

    #[test]
    fn skip_words_steps_over_breaks() {
        let t = tokenize("a b\n\nc d");
        assert_eq!(skip_words(&t, 0, 3, true), t.len() - 1);
        assert_eq!(skip_words(&t, 0, 9, false), 0);
    }
}
