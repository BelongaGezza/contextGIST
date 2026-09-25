import AppKit
import SwiftUI

// ── Display token ────────────────────────────────────────────────────────────

/// A word token plus its precomputed ORP (Optimal Recognition Point) byte
/// offset, so the word display can center each word around a fixed focal
/// letter without an FFI round trip on every tick. ORP is computed once per
/// token at load time via `orpIndex(word:)` — see contextgist-ffi.
private struct DisplayToken {
    let text: String
    let kind: FfiTokenKind
    /// Byte offset of the ORP character; meaningless for non-word tokens.
    let orpByteOffset: Int

    init(_ token: FfiToken) {
        text = token.text
        kind = token.kind
        orpByteOffset = token.kind == .word ? Int(orpIndex(word: token.text)) : 0
    }

    /// Splits `text` into (before ORP char, ORP char, after ORP char).
    var orpParts: (prefix: String, focus: String, suffix: String) {
        guard !text.isEmpty else { return ("", "", "") }
        // UTF-8 byte offset -> String.Index (ORP offsets from Rust are byte offsets).
        let utf8View = text.utf8
        let byteIdx = utf8View.index(utf8View.startIndex, offsetBy: min(orpByteOffset, utf8View.count))
        guard let charIdx = byteIdx.samePosition(in: text) else {
            return (text, "", "")
        }
        let prefix = String(text[text.startIndex..<charIdx])
        let focusEnd = text.index(after: charIdx)
        let focus = String(text[charIdx..<focusEnd])
        let suffix = focusEnd < text.endIndex ? String(text[focusEnd...]) : ""
        return (prefix, focus, suffix)
    }
}

// ── Wall-clock-anchored pacing engine ───────────────────────────────────────
//
// Ported from gist_rsvp::RsvpSession's cursor/elapsed model
// (~/develop/reader/crates/gist-rsvp/src/lib.rs), following the same
// wall-clock-anchored approach GIST's own Swift shell uses (see
// RsvpWallClockEngine in reader/apps/apple/macOS/RsvpView.swift) rather than
// a per-tick FFI call: recomputes which token should be showing from actual
// elapsed time on every tick, so a late/coalesced wake self-corrects instead
// of drifting. Keep in sync with gist-rsvp if pacing rules change there.
private struct PacingEngine {
    private(set) var cursor: Int
    private(set) var resumeDate: Date?

    init(cursor: Int) {
        self.cursor = cursor
        self.resumeDate = nil
    }

    var isPlaying: Bool { resumeDate != nil }
    static let notPlayingRemainingMs = UInt64.max

    func currentIndex(tokens: [DisplayToken], config: FfiRsvpConfig, wpm: UInt32, at now: Date) -> (index: Int, remainingMs: UInt64) {
        guard let resumeDate else {
            return (min(cursor, max(tokens.count - 1, 0)), Self.notPlayingRemainingMs)
        }
        let elapsedMs = Self.elapsedMs(from: resumeDate, to: now)
        return Self.tokenAtElapsed(tokens: tokens, config: config, wpm: wpm, cursor: cursor, elapsedMs: elapsedMs)
    }

    mutating func pause(tokens: [DisplayToken], config: FfiRsvpConfig, wpm: UInt32, at now: Date) {
        guard let resumeDate else { return }
        let elapsedMs = Self.elapsedMs(from: resumeDate, to: now)
        cursor = Self.tokenAtElapsed(tokens: tokens, config: config, wpm: wpm, cursor: cursor, elapsedMs: elapsedMs).index
        self.resumeDate = nil
    }

    mutating func resume(at now: Date) {
        resumeDate = now
    }

    mutating func seek(to index: Int, tokenCount: Int) {
        cursor = max(0, min(index, tokenCount - 1))
        resumeDate = nil
    }

    mutating func setWpm(tokens: [DisplayToken], config: FfiRsvpConfig, oldWpm: UInt32, at now: Date) {
        guard let resumeDate else { return }
        let elapsedMs = Self.elapsedMs(from: resumeDate, to: now)
        cursor = Self.tokenAtElapsed(tokens: tokens, config: config, wpm: oldWpm, cursor: cursor, elapsedMs: elapsedMs).index
        self.resumeDate = now
    }

    private static func elapsedMs(from start: Date, to now: Date) -> UInt64 {
        UInt64(max(0, now.timeIntervalSince(start)) * 1000)
    }

    static func tokenDurationMs(tokens: [DisplayToken], config: FfiRsvpConfig, wpm: UInt32, idx: Int) -> UInt64 {
        guard tokens.indices.contains(idx) else { return 0 }
        let clampedWpm = min(max(wpm, 100), 1000)
        let baseMs = 60_000 / UInt64(clampedWpm)
        let token = tokens[idx]

        let multiplier: Double
        switch token.kind {
        case .paragraphBreak, .sectionBreak:
            multiplier = Double(config.pauseParagraph)
        case .word:
            let text = token.text
            if isNumeral(text) {
                let punct = endsSentence(text) ? Double(config.pauseSentence)
                    : (endsClause(text) ? Double(config.pauseComma) : 1.0)
                multiplier = max(Double(config.pauseNumeral), punct)
            } else if endsSentence(text) {
                multiplier = Double(config.pauseSentence)
            } else if endsClause(text) {
                multiplier = Double(config.pauseComma)
            } else {
                multiplier = 1.0
            }
        }
        return UInt64((Double(baseMs) * multiplier).rounded())
    }

    static func tokenAtElapsed(
        tokens: [DisplayToken], config: FfiRsvpConfig, wpm: UInt32, cursor: Int, elapsedMs: UInt64
    ) -> (index: Int, remainingMs: UInt64) {
        guard !tokens.isEmpty else { return (0, 0) }
        var accumulated: UInt64 = 0
        var idx = max(cursor, 0)
        while idx < tokens.count {
            let dur = tokenDurationMs(tokens: tokens, config: config, wpm: wpm, idx: idx)
            if accumulated + dur > elapsedMs {
                return (idx, accumulated + dur - elapsedMs)
            }
            accumulated += dur
            idx += 1
        }
        return (max(tokens.count - 1, 0), 0)
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.reversed().drop {
            !($0.isLetter || $0.isNumber) && $0 != "." && $0 != "!" && $0 != "?"
        }
        guard let last = trimmed.first else { return false }
        return last == "." || last == "!" || last == "?"
    }

    private static func endsClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "," || last == ";" || last == ":"
    }

    private static func isNumeral(_ text: String) -> Bool {
        !text.isEmpty
            && text.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
            && text.contains { $0.isASCII && $0.isNumber }
    }
}

/// Walks `tokens` from `from`, counting only `.word` tokens, `n` steps in
/// `direction` (-1 = backward, +1 = forward). Mirrors
/// `gist_rsvp::RsvpSession::back_words`, extended with a symmetric forward
/// jump for the "fast-forward" control.
private func skipWords(tokens: [DisplayToken], from: Int, by n: Int, direction: Int) -> Int {
    var target = from
    var skipped = 0
    while skipped < n {
        let next = target + direction
        guard tokens.indices.contains(next) else { break }
        target = next
        if tokens[target].kind == .word {
            skipped += 1
        }
    }
    return max(0, min(target, tokens.count - 1))
}

// ── Player ───────────────────────────────────────────────────────────────────

@MainActor
private final class RsvpPlayer: ObservableObject {
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var wpm: UInt32

    private let tokens: [DisplayToken]
    private let config: FfiRsvpConfig
    private var engine: PacingEngine
    private var tickTask: Task<Void, Never>?

    var currentToken: DisplayToken? {
        tokens.indices.contains(currentIndex) ? tokens[currentIndex] : nil
    }

    var progressText: String? {
        let wordCount = tokens.filter { $0.kind == .word }.count
        guard wordCount > 0 else { return nil }
        let wordsShown = tokens[...currentIndex].filter { $0.kind == .word }.count
        return "\(wordsShown) / \(wordCount)"
    }

    var isAtEnd: Bool { currentIndex >= tokens.count - 1 }

    init(text: String) {
        let ffiTokens = tokenize(text: text)
        tokens = ffiTokens.map(DisplayToken.init)
        config = defaultConfig()
        wpm = config.wpm
        engine = PacingEngine(cursor: 0)
    }

    func play() {
        guard !isPlaying, !tokens.isEmpty, !isAtEnd else { return }
        isPlaying = true
        engine.resume(at: Date())
        scheduleNextTick()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
        let now = Date()
        engine.pause(tokens: tokens, config: config, wpm: wpm, at: now)
        currentIndex = engine.currentIndex(tokens: tokens, config: config, wpm: wpm, at: now).index
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func rewind(words: Int = 5) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        let target = skipWords(tokens: tokens, from: currentIndex, by: words, direction: -1)
        engine.seek(to: target, tokenCount: tokens.count)
        currentIndex = target
        if wasPlaying { play() }
    }

    func fastForward(words: Int = 5) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        let target = skipWords(tokens: tokens, from: currentIndex, by: words, direction: 1)
        engine.seek(to: target, tokenCount: tokens.count)
        currentIndex = target
        if wasPlaying { play() }
    }

    func setWpm(_ newWpm: UInt32) {
        let clamped = min(max(newWpm, 100), 1000)
        guard clamped != wpm else { return }
        let now = Date()
        engine.setWpm(tokens: tokens, config: config, oldWpm: wpm, at: now)
        wpm = clamped
        currentIndex = engine.currentIndex(tokens: tokens, config: config, wpm: wpm, at: now).index
        if isPlaying {
            scheduleNextTick()
        }
    }

    private func scheduleNextTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, self.isPlaying {
                let now = Date()
                let (idx, remainingMs) = self.engine.currentIndex(tokens: self.tokens, config: self.config, wpm: self.wpm, at: now)
                guard remainingMs != PacingEngine.notPlayingRemainingMs else { return }
                self.currentIndex = idx
                if idx >= self.tokens.count - 1 {
                    self.pause()
                    return
                }
                let sleepMs = max(remainingMs, 1)
                try? await Task.sleep(nanoseconds: sleepMs * 1_000_000)
                if Task.isCancelled { return }
            }
        }
    }
}

// ── ORP-centered word display ───────────────────────────────────────────────

private let wordDisplayFontSize: CGFloat = 40
private let wordDisplayFont = Font.system(size: wordDisplayFontSize, weight: .medium, design: .monospaced)

/// Advance width of one character in `wordDisplayFont`, measured once. Since
/// the font is monospaced, every character (including the ORP focus glyph)
/// has this same advance width, so prefix/suffix pixel widths can be derived
/// from character counts alone — no per-word text measurement needed.
private let wordDisplayCharWidth: CGFloat = {
    let font = NSFont.monospacedSystemFont(ofSize: wordDisplayFontSize, weight: .medium)
    return NSAttributedString(string: "0", attributes: [.font: font]).size().width
}()

/// Centers a word around its ORP character by offsetting the whole row by
/// half the (prefix width − suffix width), so the focal letter's x-position
/// stays fixed regardless of word length — the standard RSVP "reticle"
/// technique. Widths are computed synchronously from character counts
/// (monospaced font) rather than via GeometryReader/PreferenceKey, which
/// would lag a render frame behind each word change and make the reticle
/// visibly jump.
private struct WordDisplay: View {
    let token: DisplayToken?

    var body: some View {
        let parts = token?.orpParts ?? (prefix: "", focus: "", suffix: "")
        let prefixWidth = CGFloat(parts.prefix.count) * wordDisplayCharWidth
        let suffixWidth = CGFloat(parts.suffix.count) * wordDisplayCharWidth
        HStack(spacing: 0) {
            Text(parts.prefix)
            Text(parts.focus).foregroundStyle(.red)
            Text(parts.suffix)
        }
        .font(wordDisplayFont)
        .offset(x: (prefixWidth - suffixWidth) / 2)
        .frame(maxWidth: .infinity, minHeight: 60)
    }
}

// ── Main view ────────────────────────────────────────────────────────────────

struct RsvpView: View {
    let text: String
    var onEscape: (() -> Void)?

    @StateObject private var player: RsvpPlayer

    init(text: String, onEscape: (() -> Void)? = nil) {
        self.text = text
        self.onEscape = onEscape
        _player = StateObject(wrappedValue: RsvpPlayer(text: text))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Fixed reticle mark above the ORP focal column.
            Text("▾").font(.caption).foregroundStyle(.secondary)
            WordDisplay(token: player.currentToken)

            if let progressText = player.progressText {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            HStack(spacing: 24) {
                Button {
                    player.rewind()
                } label: {
                    Image(systemName: "gobackward.5")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Rewind 5 words")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.fastForward()
                } label: {
                    Image(systemName: "goforward.5")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Fast-forward 5 words")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 20))

            VStack(spacing: 4) {
                Text("\(player.wpm) WPM").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Slider(
                    value: Binding(
                        get: { Double(player.wpm) },
                        set: { player.setWpm(UInt32($0.rounded())) }
                    ),
                    in: 100...1000,
                    step: 10
                )
                .frame(width: 260)
                .accessibilityLabel("Reading speed")
            }

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 300)
        .background(
            Button("Close") { onEscape?() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        )
        .onAppear { player.play() }
    }
}
