//! Minimal FFI surface for contextGIST.
//!
//! contextGIST has no library, no persistence, and no per-tick FFI calls —
//! the Swift shell fetches a token stream and a default pacing config once
//! per popup, then drives playback itself (same wall-clock-anchored pattern
//! as GIST's own `RsvpPlayer`, see apps/apple/macOS/RsvpView.swift in
//! ~/develop/reader). This crate exists only to convert selected text into
//! that token stream using GIST's real tokenizer, so pacing/pause rules
//! never drift from upstream.

uniffi::setup_scaffolding!();

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
/// ~/develop/reader). Never fails: a selection that somehow blows past
/// `ParseLimits::default()` (256 MB) just yields no tokens rather than
/// erroring the popup out — that ceiling is unreachable for a real text
/// selection, so surfacing it as a user-facing error isn't worth the API
/// surface.
#[uniffi::export]
pub fn tokenize(text: String) -> Vec<FfiToken> {
    let limits = gist_model::ParseLimits::default();
    match gist_parse_txt::parse(text.as_bytes(), "selection", &limits) {
        Ok(doc) => doc.token_stream.into_iter().map(FfiToken::from).collect(),
        Err(_) => Vec::new(),
    }
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
#[uniffi::export]
pub fn orp_index(word: String) -> u32 {
    gist_rsvp::orp_index(&word) as u32
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
        assert_eq!(orp_index("Hello".to_string()), gist_rsvp::orp_index("Hello") as u32);
    }
}
