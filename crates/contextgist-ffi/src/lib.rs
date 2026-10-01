//! Minimal FFI surface for contextGIST.
//!
//! contextGIST has no library, no persistence, and no per-tick FFI calls —
//! the Swift shell fetches a token stream and a default pacing config once
//! per popup, then drives playback itself (same wall-clock-anchored pattern
//! as GIST's own `RsvpPlayer`, see apps/apple/macOS/RsvpView.swift in
//! github.com/BelongaGezza/gist). This crate exists only to convert selected text into
//! that token stream using GIST's real tokenizer, so pacing/pause rules
//! never drift from upstream.

uniffi::setup_scaffolding!();

// ── Panic containment ────────────────────────────────────────────────────────

/// Runs `f`, turning a panic into `fallback` instead of letting it reach
/// Swift. uniffi already catches panics at the boundary, but for these
/// infallible exports the generated Swift calls `try! rustCall(...)`, so a
/// caught panic still becomes a Swift trap: a crash, and a crash report
/// written while the selection is in memory (docs/SECURITY_REVIEW.md
/// finding #1). Degrading to an empty/neutral result keeps the popup alive.
///
/// Also installs a panic hook that prints nothing, once per process. Rust's
/// default hook writes the panic message to stderr, and some std panic
/// messages quote the string being operated on (e.g. `str` slicing's "byte
/// index N is not a char boundary ... of `<text>`"), which would put
/// selected text somewhere it could be captured.
fn contain<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    // Not under `cargo test`: the hook is process-wide and would also
    // swallow the test harness's own assertion messages.
    #[cfg(not(test))]
    {
        static SILENCE_PANICS: std::sync::Once = std::sync::Once::new();
        SILENCE_PANICS.call_once(|| std::panic::set_hook(Box::new(|_| {})));
    }
    std::panic::catch_unwind(f).unwrap_or(fallback)
}

// ── Token ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTokenKind {
    Word,
    ParagraphBreak,
    SectionBreak,
}

impl From<gist_model::TokenKind> for FfiTokenKind {
    fn from(k: gist_model::TokenKind) -> Self {
        match k {
            gist_model::TokenKind::Word => FfiTokenKind::Word,
            gist_model::TokenKind::ParagraphBreak => FfiTokenKind::ParagraphBreak,
            gist_model::TokenKind::SectionBreak => FfiTokenKind::SectionBreak,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiToken {
    pub text: String,
    pub kind: FfiTokenKind,
}

impl From<gist_model::Token> for FfiToken {
    fn from(t: gist_model::Token) -> Self {
        FfiToken {
            text: t.text,
            kind: t.kind.into(),
        }
    }
}

/// Tokenize raw selected text exactly as GIST's plain-text importer would
/// (blank-line-separated paragraphs, whitespace-split words — see
/// `gist_parse_txt::parse` and `Document::build_token_stream` in
/// github.com/BelongaGezza/gist). Never fails: a selection that somehow blows past
/// `ParseLimits::default()` (256 MB) just yields no tokens rather than
/// erroring the popup out — that ceiling is unreachable for a real text
/// selection, so surfacing it as a user-facing error isn't worth the API
/// surface. The Swift side caps selections far below that anyway (see
/// `AppServiceProvider.maxSelectionBytes`). A panic also yields no tokens
/// (see `contain`).
#[uniffi::export]
pub fn tokenize(text: String) -> Vec<FfiToken> {
    contain(Vec::new(), move || {
        let limits = gist_model::ParseLimits::default();
        match gist_parse_txt::parse(text.as_bytes(), "selection", &limits) {
            Ok(doc) => doc.token_stream.into_iter().map(FfiToken::from).collect(),
            Err(_) => Vec::new(),
        }
    })
}

// ── Pacing config ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRsvpConfig {
    pub wpm: u32,
    pub pause_sentence: f32,
    pub pause_comma: f32,
    pub pause_paragraph: f32,
    pub pause_numeral: f32,
    pub chunk_size: u32,
}

impl From<gist_rsvp::Config> for FfiRsvpConfig {
    fn from(c: gist_rsvp::Config) -> Self {
        FfiRsvpConfig {
            wpm: c.wpm,
            pause_sentence: c.pause_sentence,
            pause_comma: c.pause_comma,
            pause_paragraph: c.pause_paragraph,
            pause_numeral: c.pause_numeral,
            chunk_size: c.chunk_size as u32,
        }
    }
}

/// GIST's default pacing config (250 WPM, etc — see `gist_rsvp::Config::default`).
#[uniffi::export]
pub fn default_config() -> FfiRsvpConfig {
    gist_rsvp::Config::default().into()
}

/// Byte offset of a word's Optimal Recognition Point, for centering the
/// word display around a fixed focal letter. See `gist_rsvp::orp_index`.
/// A panic yields 0 (the word's first character) rather than a crash.
#[uniffi::export]
pub fn orp_index(word: String) -> u32 {
    contain(0, move || gist_rsvp::orp_index(&word) as u32)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_splits_words_and_paragraphs() {
        let tokens = tokenize("Hello world.\n\nSecond paragraph.".to_string());
        let kinds: Vec<FfiTokenKind> = tokens.iter().map(|t| t.kind).collect();
        assert!(kinds.contains(&FfiTokenKind::ParagraphBreak));
        assert_eq!(tokens[0].text, "Hello");
        assert_eq!(tokens[0].kind, FfiTokenKind::Word);
    }

    #[test]
    fn tokenize_empty_text_yields_no_word_tokens() {
        let tokens = tokenize(String::new());
        assert!(tokens.iter().all(|t| t.kind != FfiTokenKind::Word));
    }

    #[test]
    fn default_config_matches_gist_rsvp() {
        let cfg = default_config();
        assert_eq!(cfg.wpm, 250);
        assert_eq!(cfg.chunk_size, 1);
    }

    #[test]
    fn orp_index_matches_gist_rsvp() {
        assert_eq!(
            orp_index("Hello".to_string()),
            gist_rsvp::orp_index("Hello") as u32
        );
    }

    #[test]
    fn contain_turns_a_panic_into_the_fallback() {
        assert_eq!(contain(7, || -> i32 { panic!("boom") }), 7);
        assert_eq!(contain(7, || 1), 1);
    }

    // ── Adversarial input (docs/DEVELOPMENT_PLAN.md Phase 0) ─────────────────
    //
    // A panic in gist-parse-txt/gist-rsvp is what would turn a bad selection
    // into a crash report containing that selection (SECURITY_REVIEW.md
    // finding #1). These call the upstream crates *directly* rather than
    // through `tokenize`/`orp_index`, because `contain` would hide the
    // panic. Every test also checks the invariant the Swift side depends on:
    // each word's ORP offset is a char boundary inside the word
    // (`DisplayToken.orpParts` converts it with `samePosition(in:)`).

    /// Tokenizes `text` via the upstream crates exactly as `tokenize` does,
    /// without panic containment, and checks per-token invariants.
    fn tokenize_checked(text: &str) -> Vec<gist_model::Token> {
        let limits = gist_model::ParseLimits::default();
        let doc = gist_parse_txt::parse(text.as_bytes(), "selection", &limits)
            .expect("valid UTF-8 under the size limit must parse");
        for t in &doc.token_stream {
            match t.kind {
                gist_model::TokenKind::Word => {
                    assert!(!t.text.is_empty(), "empty word token from {text:?}");
                    assert!(
                        !t.text.chars().any(char::is_whitespace),
                        "word token contains whitespace: {:?}",
                        t.text
                    );
                    let orp = gist_rsvp::orp_index(&t.text);
                    assert!(
                        orp < t.text.len(),
                        "ORP {orp} out of range for {:?}",
                        t.text
                    );
                    assert!(
                        t.text.is_char_boundary(orp),
                        "ORP {orp} not a char boundary in {:?}",
                        t.text
                    );
                }
                _ => assert!(t.text.is_empty()),
            }
        }
        doc.token_stream
    }

    fn words(tokens: &[gist_model::Token]) -> Vec<&str> {
        tokens
            .iter()
            .filter(|t| t.kind == gist_model::TokenKind::Word)
            .map(|t| t.text.as_str())
            .collect()
    }

    #[test]
    fn very_long_word_without_whitespace() {
        let word = "a".repeat(512 * 1024);
        let tokens = tokenize_checked(&word);
        assert_eq!(words(&tokens), vec![word.as_str()]);

        // Multi-byte chars only, so every byte offset but a few is mid-char.
        let word = "é".repeat(100_000);
        assert_eq!(words(&tokenize_checked(&word)).len(), 1);
    }

    #[test]
    fn bidi_and_rtl_text() {
        let text =
            "Hello \u{202E}dlrow\u{202C} שלום עולם مرحبا بالعالم \u{2067}isolate\u{2069} end.";
        let w = tokenize_checked(text);
        assert_eq!(words(&w).len(), 8);
        // Directional control characters stay attached to their words; they
        // aren't whitespace.
        assert!(words(&w).contains(&"\u{202E}dlrow\u{202C}"));
    }

    #[test]
    fn zero_width_joiners_emoji_and_combining_marks() {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦";
        let flag = "🇬🇧";
        let combining = "e\u{0301}\u{0302}\u{0303}";
        let zwsp_word = "zero\u{200B}width";
        let text = format!("{family} {flag} {combining} {zwsp_word}");
        let w = tokenize_checked(&text);
        // U+200B ZERO WIDTH SPACE is not Unicode White_Space, so it doesn't
        // split words.
        assert_eq!(words(&w), vec![family, flag, combining, zwsp_word]);
    }

    #[test]
    fn degenerate_whitespace() {
        for text in [
            "",
            " ",
            "\n\n\n\n",
            "\t \r\n \u{00A0}\u{2028}\u{2029}\u{3000}\u{FEFF}",
            &"\n\n".repeat(50_000),
            &" ".repeat(512 * 1024),
        ] {
            let w = tokenize_checked(text);
            // U+FEFF (BOM / ZWNBSP) is not White_Space, so the one mixed
            // case yields exactly that as a "word". Everything else: none.
            let expected = usize::from(text.contains('\u{FEFF}'));
            assert_eq!(
                words(&w).len(),
                expected,
                "for {:?}",
                &text[..text.len().min(40)]
            );
        }
    }

    #[test]
    fn line_ending_styles() {
        // Every way of writing a blank line gives a paragraph break: LF,
        // CRLF (Windows), bare CR (e.g. Word), U+2029 PARAGRAPH SEPARATOR,
        // and whitespace-only "blank" lines. Before GIST 695fba1 only a
        // literal "\n\n" did, so the others lost their paragraph pauses
        // (https://github.com/BelongaGezza/gist/issues/76, filed from
        // here). This test pinned the bug until upstream fixed it.
        for (text, breaks) in [
            ("one two\n\nthree", 1),
            ("one two\r\n\r\nthree", 1),
            ("one two\r\rthree", 1),
            ("one two\u{2029}three", 1),
            ("one two\n \nthree", 1),
        ] {
            let tokens = tokenize_checked(text);
            assert_eq!(words(&tokens), vec!["one", "two", "three"], "for {text:?}");
            let n = tokens
                .iter()
                .filter(|t| t.kind == gist_model::TokenKind::ParagraphBreak)
                .count();
            assert_eq!(n, breaks, "paragraph breaks for {text:?}");
        }
    }

    #[test]
    fn control_characters_and_nul() {
        let text = "a\0b \u{7}bell \u{1B}[31mred\u{1B}[0m \u{FFFD} \u{10FFFF}";
        assert_eq!(words(&tokenize_checked(text)).len(), 5);
    }

    #[test]
    fn orp_index_on_single_chars_and_edge_words() {
        for w in [
            "a",
            "é",
            "👨\u{200D}👩",
            "\u{0301}",
            "xyzxyz",
            "AEIOU",
            "ßẞ",
            "ﷺ",
        ] {
            let orp = gist_rsvp::orp_index(w);
            assert!(w.is_char_boundary(orp) && orp < w.len(), "{w:?} -> {orp}");
        }
        assert_eq!(gist_rsvp::orp_index(""), 0);
    }

    /// Deterministic pseudo-fuzz over a pool of awkward characters. No
    /// proptest dependency: a fixed-seed xorshift keeps failures
    /// reproducible from the printed seed/iteration.
    #[test]
    fn randomized_awkward_strings() {
        const POOL: &[&str] = &[
            "a", "E", "z", " ", "\n", "\n\n", "\r", "\t", "\u{00A0}", "\u{2028}", "\u{2029}",
            "\u{3000}", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{202E}", "\u{2067}", "\u{0301}",
            "é", "ß", "ﷺ", "ש", "م", "中", "👨", "🇬", "\0", ".", ",", "1", "!", "?",
        ];
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for iteration in 0..5_000 {
            let len = (next() % 64) as usize;
            let text: String = (0..len)
                .map(|_| POOL[(next() % POOL.len() as u64) as usize])
                .collect();
            let result = std::panic::catch_unwind(|| tokenize_checked(&text));
            assert!(result.is_ok(), "iteration {iteration} panicked on {text:?}");
        }
    }
}
