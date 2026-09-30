import Testing

@testable import AppCore

@Suite struct PrompterScrollTests {
    @Test func readsTheWholeScriptInTheTimeItTakesToSayIt() {
        // 300 words at 150 wpm take 2 min: 1200 pt of scrolling → 10 pt/s, whatever the font or width.
        #expect(PrompterScroll.pointsPerSecond(scrollableHeight: 1200, wordCount: 300, wordsPerMinute: 150) == 10)
        #expect(PrompterScroll.pointsPerSecond(scrollableHeight: 0, wordCount: 300, wordsPerMinute: 150) == 0)
        #expect(PrompterScroll.pointsPerSecond(scrollableHeight: 500, wordCount: 0, wordsPerMinute: 150) == 0)
    }

    @Test func stopsAtTheEndAndNeverGoesNegative() {
        #expect(PrompterScroll.advance(990, by: 1, speed: 20, maxOffset: 1000) == 1000)
        #expect(PrompterScroll.advance(5, by: 1, speed: -20, maxOffset: 1000) == 0)
        #expect(PrompterScroll.advance(0, by: 1, speed: 20, maxOffset: -50) == 0)
    }
}
