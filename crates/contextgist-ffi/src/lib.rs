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

#[cfg(test)]
use contextgist_core::skip_words;
use contextgist_core::tokenize as tokenize_inner;
pub use contextgist_core::MAX_SELECTION_BYTES;

// ── Panic containment ────────────────────────────────────────────────────────

/// Runs `f`, turning a panic into `fallback` instead of letting it reach
/// Swift. uniffi already catches panics at the boundary, but for these
/// infallible exports the generated Swift calls `try! rustCall(...)`, so a
/// caught panic still becomes a Swift trap (see `contextgist_core::contain`).
fn contain<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    // Not under `cargo test`: the hook is process-wide and would also
    // swallow the test harness's own assertion messages.
    #[cfg(not(test))]
    contextgist_core::silence_panic_messages();
    contextgist_core::contain(fallback, f)
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

/// Tokenize raw selected text as GIST's plain-text importer would
/// (blank-line-separated paragraphs, whitespace-split words — see
/// `gist_parse_txt::parse` and `Document::build_token_stream` in
/// github.com/BelongaGezza/gist), UTF-8 only, capped at
/// [`MAX_SELECTION_BYTES`], with over-long words split (see
/// `tokenize_inner`). Never fails: anything rejected yields no tokens rather
/// than erroring the popup out. A panic also yields no tokens (see
/// `contain`).
#[uniffi::export]
pub fn tokenize(text: String) -> Vec<FfiToken> {
    contain(Vec::new(), move || {
        tokenize_inner(&text)
            .into_iter()
            .map(FfiToken::from)
            .collect()
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
    contextgist_core::default_config().into()
}

/// Byte offset of a word's Optimal Recognition Point, for centering the
/// word display around a fixed focal letter. See `gist_rsvp::orp_index`.
/// A panic yields 0 (the word's first character) rather than a crash.
#[uniffi::export]
pub fn orp_index(word: String) -> u32 {
    contain(0, move || contextgist_core::orp_index(&word) as u32)
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

    /// Tokenizes `text` exactly as `tokenize` does (shared `tokenize_inner`),
    /// without panic containment, and checks per-token invariants.
    fn tokenize_checked(text: &str) -> Vec<gist_model::Token> {
        let tokens = tokenize_inner(text);
        for t in &tokens {
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
        tokens
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
        // A 512 KiB word is split into <=256-byte chunks (as RsvpSession does)
        // that concatenate back to the original.
        let word = "a".repeat(MAX_SELECTION_BYTES);
        let tokens = tokenize_checked(&word);
        let chunks = words(&tokens);
        assert!(chunks.iter().all(|c| c.len() <= gist_rsvp::MAX_TOKEN_BYTES));
        assert_eq!(chunks.concat(), word);

        // Multi-byte chars only, so every byte offset but a few is mid-char.
        let word = "é".repeat(100_000);
        let tokens = tokenize_checked(&word);
        let chunks = words(&tokens);
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|c| c.len() <= gist_rsvp::MAX_TOKEN_BYTES));
        assert_eq!(chunks.concat(), word);
    }

    #[test]
    fn oversized_words_are_split_like_rsvp_session() {
        let cases = [
            "x".repeat(300),
            "é".repeat(200),
            // combining-mark run: one grapheme cluster far over the limit
            format!("e{}", "\u{0301}".repeat(400)),
            "👍🏽".repeat(40),
            "🇬🇧".repeat(40),
        ];
        for word in cases {
            let tokens = tokenize_checked(&word);
            let chunks = words(&tokens);
            assert!(chunks.len() > 1, "{:.20?} not split", word);
            assert!(chunks.iter().all(|c| c.len() <= gist_rsvp::MAX_TOKEN_BYTES));
            assert_eq!(chunks.concat(), word);
            // Same tokens RsvpSession would use.
            let via_session = gist_rsvp::RsvpSession::new(
                gist_parse_txt::parse(word.as_bytes(), "t", &gist_model::ParseLimits::default())
                    .unwrap()
                    .token_stream,
                gist_rsvp::Config::default(),
            );
            assert_eq!(format!("{tokens:?}"), format!("{:?}", via_session.tokens));
        }
    }

    #[test]
    fn selection_over_the_cap_yields_no_tokens() {
        let at_cap = "word ".repeat(MAX_SELECTION_BYTES / 5);
        assert!(at_cap.len() <= MAX_SELECTION_BYTES);
        assert!(!tokenize(at_cap).is_empty());
        let over = "a".repeat(MAX_SELECTION_BYTES + 1);
        assert!(tokenize(over).is_empty());
        assert!(tokenize("word ".repeat(120_000)).is_empty()); // 600 KB
    }

    #[test]
    fn selection_is_parsed_as_utf8_not_sniffed_as_utf16() {
        // NUL-interleaved text would be auto-detected as UTF-16 and shown as
        // "abcdefgh"; as UTF-8 each NUL stays inside its word.
        let nul_interleaved = "a\0b\0c\0d\0e\0f\0g\0h\0";
        let tokens = tokenize(nul_interleaved.to_string());
        let text: String = tokens.iter().map(|t| t.text.as_str()).collect();
        assert_eq!(text, nul_interleaved);
        assert!(!tokens.iter().any(|t| t.text == "abcdefgh"));
    }

    #[test]
    fn leading_bom_is_dropped_and_not_a_word() {
        let tokens = tokenize("\u{FEFF}hello world".to_string());
        let w: Vec<&str> = tokens.iter().map(|t| t.text.as_str()).collect();
        assert_eq!(w, vec!["hello", "world"]);
    }

    #[test]
    fn tokenize_words_match_split_whitespace_for_plain_text() {
        let text = "alpha  beta\tgamma\r\ndelta\n\nepsilon  zeta\u{00A0}eta";
        let tokens = tokenize(text.to_string());
        let got: Vec<&str> = tokens
            .iter()
            .filter(|t| t.kind == FfiTokenKind::Word)
            .map(|t| t.text.as_str())
            .collect();
        assert_eq!(got, text.split_whitespace().collect::<Vec<_>>());
    }

    #[test]
    fn skip_words_backward_matches_rsvp_session_back_words() {
        let tokens = tokenize_checked(GOLDEN_TEXT);
        let cfg = gist_rsvp::Config::default();
        for cursor in 0..tokens.len() {
            for n in [0usize, 1, 2, 5, 50, 10_000] {
                let mut session = gist_rsvp::RsvpSession::new(tokens.clone(), cfg.clone());
                session.cursor = cursor;
                session.back_words(n, 0); // elapsed 0: current token == cursor
                assert_eq!(
                    skip_words(&tokens, cursor, n, false),
                    session.cursor,
                    "cursor {cursor}, n {n}"
                );
            }
        }
    }

    #[test]
    fn skip_words_clamps_and_steps_over_breaks() {
        let tokens = tokenize_checked("one two\n\nthree four");
        // tokens: one two <break> three four
        assert_eq!(tokens.len(), 5);
        assert_eq!(skip_words(&tokens, 0, 0, true), 0);
        assert_eq!(skip_words(&tokens, 0, 2, true), 3); // one -> two -> (break) three
        assert_eq!(skip_words(&tokens, 0, 99, true), 4);
        assert_eq!(skip_words(&tokens, 4, 1, true), 4);
        assert_eq!(skip_words(&tokens, 0, 1, false), 0);
        assert_eq!(skip_words(&tokens, 4, 99, false), 0);
        assert_eq!(skip_words(&[], 0, 3, true), 0);
        assert_eq!(skip_words(&tokens, 99, 1, false), 3); // `from` clamped to last
    }

    #[test]
    fn default_config_matches_gist_rsvp_on_every_field() {
        let c = default_config();
        let g = gist_rsvp::Config::default();
        assert_eq!(c.wpm, g.wpm);
        assert_eq!(c.pause_sentence, g.pause_sentence);
        assert_eq!(c.pause_comma, g.pause_comma);
        assert_eq!(c.pause_paragraph, g.pause_paragraph);
        assert_eq!(c.pause_numeral, g.pause_numeral);
        assert_eq!(c.chunk_size as usize, g.chunk_size);
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

    /// The FFI's ORP offset must land on a Swift `Character` (extended
    /// grapheme cluster) boundary, since `DisplayToken.orpParts` falls back
    /// to "no focus letter" when `samePosition(in:)` fails. Pins GIST
    /// `fb6946a` (orp_index counts grapheme clusters, not chars).
    #[test]
    fn ffi_orp_index_is_a_grapheme_cluster_boundary() {
        use unicode_segmentation::UnicodeSegmentation;
        for w in [
            "Hello",
            "naïve",
            "re\u{0301}sume\u{0301}",
            "👍🏽",
            "🇬🇧",
            "🇬🇧🇫🇷 flags",
            "👨\u{200D}👩\u{200D}👧 family",
            "a👍🏽b",
            "e\u{0301}\u{0302}\u{0303}x",
        ] {
            let i = orp_index(w.to_string()) as usize;
            assert!(
                w.grapheme_indices(true).any(|(b, _)| b == i),
                "{w:?} -> {i} is not a cluster boundary"
            );
        }
        assert_eq!(orp_index("👍🏽".to_string()), 0);
        assert_eq!(orp_index("🇬🇧".to_string()), 0);
    }

    // ── Golden parity data for the Swift tests ──────────────────────────────
    //
    // `apps/macos/Tests/golden.json` holds tokenization, ORP offsets, token
    // durations and `token_at_elapsed` results produced by the real GIST
    // crates. The Swift `PacingEngine`/`DisplayToken` tests (apps/macos/Tests)
    // must reproduce them exactly, so a drift between the hand-ported Swift
    // and gist-rsvp fails CI. This test fails if the committed file is stale
    // (e.g. after moving the GIST pin); regenerate with
    //   UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden
    // then re-run the Swift tests.

    const GOLDEN_TEXT: &str = "Hello, world. It was 3.14 or 1,000. Wait! \"Quoted?\" (done.) \
        U.S.A. rocks; so… ok: fine\n\nSecond paragraph, with 42 and 7. \
        naïve 👍🏽 🇬🇧 re\u{0301}sume\u{0301} 👨\u{200D}👩x end";
    const GOLDEN_WPMS: [u32; 7] = [50, 100, 250, 333, 600, 1000, 5000];
    const GOLDEN_ELAPSED: [u64; 9] = [0, 1, 59, 60, 239, 240, 1000, 5000, 1_000_000];

    fn json_str(s: &str) -> String {
        let mut out = String::from("\"");
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
        out
    }

    fn golden_json() -> String {
        let tokens = tokenize_checked(GOLDEN_TEXT);
        let kind = |t: &gist_model::Token| match t.kind {
            gist_model::TokenKind::Word => "word",
            gist_model::TokenKind::ParagraphBreak => "paragraphBreak",
            gist_model::TokenKind::SectionBreak => "sectionBreak",
        };
        let mut o = String::from("{\n");
        o.push_str(&format!("  \"text\": {},\n", json_str(GOLDEN_TEXT)));
        let cfg = gist_rsvp::Config::default();
        o.push_str(&format!(
            "  \"config\": {{\"pauseSentence\": {}, \"pauseComma\": {}, \"pauseParagraph\": {}, \"pauseNumeral\": {}}},\n",
            cfg.pause_sentence, cfg.pause_comma, cfg.pause_paragraph, cfg.pause_numeral
        ));
        o.push_str("  \"tokens\": [\n");
        let rows: Vec<String> = tokens
            .iter()
            .map(|t| {
                let orp = if t.kind == gist_model::TokenKind::Word {
                    gist_rsvp::orp_index(&t.text)
                } else {
                    0
                };
                format!(
                    "    {{\"text\": {}, \"kind\": \"{}\", \"orp\": {}}}",
                    json_str(&t.text),
                    kind(t),
                    orp
                )
            })
            .collect();
        o.push_str(&rows.join(",\n"));
        o.push_str("\n  ],\n  \"durations\": [\n");
        let mut drows = Vec::new();
        let mut arows = Vec::new();
        for wpm in GOLDEN_WPMS {
            let mut session = gist_rsvp::RsvpSession::new(
                tokens.clone(),
                gist_rsvp::Config {
                    wpm,
                    ..gist_rsvp::Config::default()
                },
            );
            let durs: Vec<String> = (0..tokens.len())
                .map(|i| session.token_duration_ms(i).to_string())
                .collect();
            drows.push(format!(
                "    {{\"wpm\": {wpm}, \"ms\": [{}]}}",
                durs.join(", ")
            ));
            for cursor in [0, 3, tokens.len() / 2, tokens.len() - 1] {
                session.cursor = cursor;
                let idx: Vec<String> = GOLDEN_ELAPSED
                    .iter()
                    .map(|&e| session.token_at_elapsed(e).to_string())
                    .collect();
                arows.push(format!(
                    "    {{\"wpm\": {wpm}, \"cursor\": {cursor}, \"index\": [{}]}}",
                    idx.join(", ")
                ));
            }
        }
        o.push_str(&drows.join(",\n"));
        o.push_str("\n  ],\n  \"elapsedMs\": [");
        o.push_str(&GOLDEN_ELAPSED.map(|e| e.to_string()).join(", "));
        o.push_str("],\n  \"atElapsed\": [\n");
        o.push_str(&arows.join(",\n"));
        o.push_str("\n  ]\n}\n");
        o
    }

    #[test]
    fn golden_file_matches_gist_rsvp() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../apps/macos/Tests/golden.json"
        );
        let fresh = golden_json();
        if std::env::var_os("UPDATE_GOLDEN").is_some() {
            std::fs::write(path, &fresh).expect("write golden.json");
            return;
        }
        let committed = std::fs::read_to_string(path)
            .expect("apps/macos/Tests/golden.json missing; run UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden");
        assert!(
            committed == fresh,
            "apps/macos/Tests/golden.json is stale vs gist-rsvp; regenerate with \
             UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden, then run the Swift tests"
        );
    }

    // ── Extended golden data (Rust-only for now) ────────────────────────────
    //
    // `crates/contextgist-ffi/testdata/golden_extended.json` extends the macOS
    // golden file with what the review of 2026-10-21 found it could not see
    // (docs/REVIEW_2026-10-21.md Q-01, Q-02, T1–T7): durations for EVERY
    // integer WPM 100..=1000 under two pacing configs (the Swift `Double`
    // multiply differs from Rust's `f32` at some WPMs for the 1.3 clause pause),
    // Unicode-punctuation tokens, oversized-word chunking, `skip_words` and
    // `set_wpm` results. The Swift tests do not read this file yet: adopting it
    // needs a macOS session (CLAUDE.md §7, PENDING_APPLE_CHANGES.md). Windows
    // and Linux shells should check against it from day one.
    // Regenerate: UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden

    const EXT_TEXT: &str = "plain end. comma, 3.14 ok? \"q.\" 1,000. a:b\n\nnext \
        x.\u{0301} x!\u{FE0F} x,\u{200D} done";

    fn ext_kind(t: &gist_model::Token) -> &'static str {
        match t.kind {
            gist_model::TokenKind::Word => "word",
            gist_model::TokenKind::ParagraphBreak => "paragraphBreak",
            gist_model::TokenKind::SectionBreak => "sectionBreak",
        }
    }

    fn extended_golden_json() -> String {
        let tokens = tokenize_checked(EXT_TEXT);
        let mut o = String::from("{\n");
        o.push_str(&format!("  \"text\": {},\n", json_str(EXT_TEXT)));
        o.push_str("  \"tokens\": [\n");
        let rows: Vec<String> = tokens
            .iter()
            .map(|t| {
                format!(
                    "    {{\"text\": {}, \"kind\": \"{}\"}}",
                    json_str(&t.text),
                    ext_kind(t)
                )
            })
            .collect();
        o.push_str(&rows.join(",\n"));
        o.push_str("\n  ],\n  \"configs\": [\n");

        let configs = [
            ("default", gist_rsvp::Config::default()),
            (
                "custom",
                gist_rsvp::Config {
                    pause_sentence: 2.5,
                    pause_comma: 1.3,
                    pause_paragraph: 3.0,
                    pause_numeral: 2.0,
                    ..gist_rsvp::Config::default()
                },
            ),
        ];
        let mut cfg_rows = Vec::new();
        for (name, cfg) in &configs {
            let mut wpm_rows = Vec::new();
            for wpm in 100u32..=1000 {
                let session = gist_rsvp::RsvpSession::new(
                    tokens.clone(),
                    gist_rsvp::Config { wpm, ..cfg.clone() },
                );
                let ms: Vec<String> = (0..session.tokens.len())
                    .map(|i| session.token_duration_ms(i).to_string())
                    .collect();
                wpm_rows.push(format!("      [{wpm}, [{}]]", ms.join(", ")));
            }
            cfg_rows.push(format!(
                "    {{\"name\": \"{name}\", \"pauseSentence\": {}, \"pauseComma\": {}, \"pauseParagraph\": {}, \"pauseNumeral\": {}, \"durations\": [\n{}\n    ]}}",
                cfg.pause_sentence,
                cfg.pause_comma,
                cfg.pause_paragraph,
                cfg.pause_numeral,
                wpm_rows.join(",\n")
            ));
        }
        o.push_str(&cfg_rows.join(",\n"));

        // Oversized-word chunking: byte length of every chunk.
        o.push_str("\n  ],\n  \"oversized\": [\n");
        let cases = [
            ("ascii300", "x".repeat(300)),
            ("e-acute200", "é".repeat(200)),
            ("combining-run", format!("e{}", "\u{0301}".repeat(400))),
            ("thumbs40", "👍🏽".repeat(40)),
            ("flags40", "🇬🇧".repeat(40)),
        ];
        let rows: Vec<String> = cases
            .iter()
            .map(|(label, word)| {
                let toks = tokenize_checked(word);
                let lens: Vec<String> = toks.iter().map(|t| t.text.len().to_string()).collect();
                format!(
                    "    {{\"label\": \"{label}\", \"inputBytes\": {}, \"chunkBytes\": [{}]}}",
                    word.len(),
                    lens.join(", ")
                )
            })
            .collect();
        o.push_str(&rows.join(",\n"));

        // skip_words: every start index, a spread of n, both directions.
        o.push_str("\n  ],\n  \"skip\": [\n");
        let mut rows = Vec::new();
        for from in 0..tokens.len() {
            for n in [0usize, 1, 2, 5, 99] {
                for forward in [false, true] {
                    rows.push(format!(
                        "    {{\"from\": {from}, \"n\": {n}, \"direction\": {}, \"to\": {}}}",
                        if forward { 1 } else { -1 },
                        skip_words(&tokens, from, n, forward)
                    ));
                }
            }
        }
        o.push_str(&rows.join(",\n"));

        // set_wpm mid-play: resulting cursor and clamped WPM.
        o.push_str("\n  ],\n  \"setWpm\": [\n");
        let mut rows = Vec::new();
        for cursor in [0usize, 3, 7] {
            for elapsed in [0u64, 1, 150, 400, 5000, 1_000_000] {
                for new_wpm in [50u32, 100, 250, 1000, 5000] {
                    let mut session =
                        gist_rsvp::RsvpSession::new(tokens.clone(), gist_rsvp::Config::default());
                    session.cursor = cursor;
                    session.set_wpm(new_wpm, elapsed);
                    rows.push(format!(
                        "    {{\"cursor\": {cursor}, \"elapsedMs\": {elapsed}, \"newWpm\": {new_wpm}, \"resultCursor\": {}, \"resultWpm\": {}}}",
                        session.cursor, session.config.wpm
                    ));
                }
            }
        }
        o.push_str(&rows.join(",\n"));
        o.push_str("\n  ]\n}\n");
        o
    }

    #[test]
    fn extended_golden_file_matches_gist_rsvp() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/golden_extended.json");
        let fresh = extended_golden_json();
        if std::env::var_os("UPDATE_GOLDEN").is_some() {
            std::fs::create_dir_all(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata"))
                .expect("create testdata dir");
            std::fs::write(path, &fresh).expect("write golden_extended.json");
            return;
        }
        let committed = std::fs::read_to_string(path).expect(
            "testdata/golden_extended.json missing; run UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden",
        );
        assert!(
            committed == fresh,
            "testdata/golden_extended.json is stale vs gist-rsvp; regenerate with \
             UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden"
        );
    }

    /// The one rounding case the review found: with `f32` arithmetic a 1.3x
    /// clause pause at 110 WPM is 709 ms; a `Double` multiply gives 708.
    #[test]
    fn clause_pause_rounds_in_f32_not_f64() {
        let tokens = tokenize_checked("a, b");
        let session = gist_rsvp::RsvpSession::new(
            tokens,
            gist_rsvp::Config {
                wpm: 110,
                ..gist_rsvp::Config::default()
            },
        );
        assert_eq!(session.token_duration_ms(0), 709);
        let base = 60_000u64 / 110;
        assert_eq!((base as f64 * f64::from(1.3f32)).round() as u64, 708);
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
