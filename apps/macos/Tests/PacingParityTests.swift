import XCTest

/// Parity tests: `PacingEngine` and `DisplayToken` (hand-ported Swift) must
/// reproduce the results of the real gist-rsvp crate. Expected values come
/// from `Tests/golden.json`, which `contextgist-ffi`'s
/// `golden_file_matches_gist_rsvp` test generates from the Rust core — see
/// that test for how to regenerate it after moving the GIST pin.
final class PacingParityTests: XCTestCase {
    private struct Golden {
        struct Tok { let text: String; let kind: String; let orp: Int }
        let text: String
        let config: FfiRsvpConfig
        let tokens: [Tok]
        let durations: [(wpm: UInt32, ms: [UInt64])]
        let elapsed: [UInt64]
        let atElapsed: [(wpm: UInt32, cursor: Int, index: [Int])]
    }

    private static func loadGolden() throws -> Golden {
        let url = try XCTUnwrap(Bundle(for: PacingParityTests.self).url(forResource: "golden", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let c = root["config"] as! [String: Double]
        var config = defaultConfig()
        config.pauseSentence = Float(c["pauseSentence"]!)
        config.pauseComma = Float(c["pauseComma"]!)
        config.pauseParagraph = Float(c["pauseParagraph"]!)
        config.pauseNumeral = Float(c["pauseNumeral"]!)
        return Golden(
            text: root["text"] as! String,
            config: config,
            tokens: (root["tokens"] as! [[String: Any]]).map {
                Golden.Tok(text: $0["text"] as! String, kind: $0["kind"] as! String, orp: $0["orp"] as! Int)
            },
            durations: (root["durations"] as! [[String: Any]]).map {
                (UInt32($0["wpm"] as! Int), ($0["ms"] as! [Int]).map { UInt64($0) })
            },
            elapsed: (root["elapsedMs"] as! [Int]).map { UInt64($0) },
            atElapsed: (root["atElapsed"] as! [[String: Any]]).map {
                (UInt32($0["wpm"] as! Int), $0["cursor"] as! Int, $0["index"] as! [Int])
            }
        )
    }

    private func displayTokens(_ g: Golden) -> [DisplayToken] {
        tokenize(text: g.text).map(DisplayToken.init)
    }

    private func kindName(_ k: FfiTokenKind) -> String {
        switch k {
        case .word: return "word"
        case .paragraphBreak: return "paragraphBreak"
        case .sectionBreak: return "sectionBreak"
        }
    }

    func testTokenizationAndOrpMatchRustCore() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        XCTAssertEqual(tokens.count, g.tokens.count)
        for (t, e) in zip(tokens, g.tokens) {
            XCTAssertEqual(t.text, e.text)
            XCTAssertEqual(kindName(t.kind), e.kind, e.text)
            XCTAssertEqual(t.orpByteOffset, e.orp, e.text)
        }
    }

    func testTokenDurationsMatchRustCore() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        for row in g.durations {
            let got = tokens.indices.map {
                PacingEngine.tokenDurationMs(tokens: tokens, config: g.config, wpm: row.wpm, idx: $0)
            }
            for i in tokens.indices {
                XCTAssertEqual(got[i], row.ms[i], "wpm \(row.wpm) token \(i) \(tokens[i].text.debugDescription)")
            }
        }
    }

    func testTokenAtElapsedMatchesRustCore() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        for row in g.atElapsed {
            for (e, expected) in zip(g.elapsed, row.index) {
                let got = PacingEngine.tokenAtElapsed(
                    tokens: tokens, config: g.config, wpm: row.wpm, cursor: row.cursor, elapsedMs: e
                ).index
                XCTAssertEqual(got, expected, "wpm \(row.wpm) cursor \(row.cursor) elapsed \(e)")
            }
        }
    }

    // ── Engine behaviour that the Rust pure functions don't cover ───────────

    func testRemainingMsCountsDownToTheNextTokenBoundary() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        let d0 = PacingEngine.tokenDurationMs(tokens: tokens, config: g.config, wpm: 250, idx: 0)
        let r = PacingEngine.tokenAtElapsed(tokens: tokens, config: g.config, wpm: 250, cursor: 0, elapsedMs: 10)
        XCTAssertEqual(r.index, 0)
        XCTAssertEqual(r.remainingMs, d0 - 10)
        let past = PacingEngine.tokenAtElapsed(tokens: tokens, config: g.config, wpm: 250, cursor: 0, elapsedMs: UInt64.max / 2)
        XCTAssertEqual(past.index, tokens.count - 1)
        XCTAssertEqual(past.remainingMs, 0)
    }

    func testWallClockEngineResumePauseAndFloatingPointRounding() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        let d0 = PacingEngine.tokenDurationMs(tokens: tokens, config: g.config, wpm: 250, idx: 0)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var engine = PacingEngine(cursor: 0)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentIndex(tokens: tokens, config: g.config, wpm: 250, at: t0).remainingMs,
                       PacingEngine.notPlayingRemainingMs)
        engine.resume(at: t0)
        XCTAssertTrue(engine.isPlaying)
        // Just before / exactly at the token boundary.
        XCTAssertEqual(engine.currentIndex(tokens: tokens, config: g.config, wpm: 250,
                                           at: t0.addingTimeInterval(Double(d0 - 1) / 1000)).index, 0)
        XCTAssertEqual(engine.currentIndex(tokens: tokens, config: g.config, wpm: 250,
                                           at: t0.addingTimeInterval(Double(d0) / 1000)).index, 1)
        engine.pause(tokens: tokens, config: g.config, wpm: 250, at: t0.addingTimeInterval(Double(d0) / 1000))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.cursor, 1)
    }

    /// A 0.4 s interval can materialize as 0.39999999999999997; it must still
    /// count as 400 ms, i.e. cross the 400 ms boundary (GIST 6717ca5).
    func testElapsedRoundingDoesNotLoseAMillisecond() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        // Token 2 ("It") is 400 ms at 150 WPM with no pause multiplier.
        XCTAssertEqual(PacingEngine.tokenDurationMs(tokens: tokens, config: g.config, wpm: 150, idx: 2), 400)
        let start = Date(timeIntervalSinceReferenceDate: 1000.1)
        let now = Date(timeIntervalSinceReferenceDate: 1000.5)
        XCTAssertLessThan(now.timeIntervalSince(start), 0.4 + 1e-12)
        var engine = PacingEngine(cursor: 2)
        engine.resume(at: start)
        XCTAssertEqual(engine.currentIndex(tokens: tokens, config: g.config, wpm: 150, at: now).index, 3)
    }

    func testSetWpmKeepsPositionAndRestartsClock() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        let d0 = PacingEngine.tokenDurationMs(tokens: tokens, config: g.config, wpm: 250, idx: 0)
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
        var engine = PacingEngine(cursor: 0)
        engine.resume(at: t0)
        let t1 = t0.addingTimeInterval(Double(d0) / 1000)
        engine.setWpm(tokens: tokens, config: g.config, oldWpm: 250, at: t1)
        XCTAssertEqual(engine.cursor, 1)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.currentIndex(tokens: tokens, config: g.config, wpm: 600, at: t1).index, 1)
    }

    func testSeekClampsAndStopsPlayback() {
        var engine = PacingEngine(cursor: 0)
        engine.resume(at: Date())
        engine.seek(to: 99, tokenCount: 10)
        XCTAssertEqual(engine.cursor, 9)
        XCTAssertFalse(engine.isPlaying)
        engine.seek(to: -4, tokenCount: 10)
        XCTAssertEqual(engine.cursor, 0)
    }

    func testSkipWordsCountsOnlyWordsAndClamps() throws {
        let g = try Self.loadGolden()
        let tokens = displayTokens(g)
        let words = tokens.indices.filter { tokens[$0].kind == .word }
        // Forward 5 words from the first word lands on the 6th word.
        XCTAssertEqual(skipWords(tokens: tokens, from: words[0], by: 5, direction: 1), words[5])
        // Crossing the paragraph break still counts only words.
        let brk = try XCTUnwrap(tokens.firstIndex { $0.kind != .word })
        let before = words.last { $0 < brk }!
        let after = words.first { $0 > brk }!
        XCTAssertEqual(skipWords(tokens: tokens, from: before, by: 1, direction: 1), after)
        XCTAssertEqual(skipWords(tokens: tokens, from: after, by: 1, direction: -1), before)
        // Clamped at both ends.
        XCTAssertEqual(skipWords(tokens: tokens, from: 2, by: 500, direction: -1), 0)
        XCTAssertEqual(skipWords(tokens: tokens, from: 2, by: 500, direction: 1), tokens.count - 1)
    }

    // ── ORP split (DisplayToken.orpParts) ───────────────────────────────────

    func testOrpPartsSplitOnWholeCharacters() throws {
        for (word, focus) in [
            ("Hello", "o"), ("👍🏽", "👍🏽"), ("🇬🇧", "🇬🇧"), ("a👍🏽b", "👍🏽"),
            ("re\u{0301}sume\u{0301}", "u"), ("n\u{0303}", "n\u{0303}"),
        ] {
            let t = DisplayToken(FfiToken(text: word, kind: .word))
            let p = t.orpParts
            XCTAssertEqual(p.prefix + p.focus + p.suffix, word, "parts must reassemble \(word)")
            XCTAssertEqual(p.focus, focus, word)
            XCTAssertEqual(p.focus.count, 1, "focus is exactly one Character in \(word)")
        }
    }

    func testOrpPartsOfBreakAndEmptyTokensAreSafe() {
        let brk = DisplayToken(FfiToken(text: "", kind: .paragraphBreak))
        XCTAssertEqual(brk.orpParts.focus, "")
    }
}
