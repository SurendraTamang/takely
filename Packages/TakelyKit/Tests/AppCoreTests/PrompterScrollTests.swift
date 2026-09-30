import Testing

@testable import AppCore

@Suite struct PrompterScrollTests {
    @Test func speakingPaceMatchesLinesOfText() {
        // 150 wpm ≈ 25 lines/min at 6 words per line → 0.4167 lines/s × (32 pt × 1.3).
        let speed = PrompterScroll.pointsPerSecond(wordsPerMinute: 150, fontSize: 32)
        #expect(abs(speed - 17.333) < 0.01)
    }

    @Test func stopsAtTheEndAndNeverGoesNegative() {
        #expect(PrompterScroll.advance(990, by: 1, speed: 20, maxOffset: 1000) == 1000)
        #expect(PrompterScroll.advance(5, by: 1, speed: -20, maxOffset: 1000) == 0)
        #expect(PrompterScroll.advance(0, by: 1, speed: 20, maxOffset: -50) == 0)
    }
}
