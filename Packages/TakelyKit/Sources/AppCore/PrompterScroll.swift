/// Teleprompter pacing: how fast the script moves so it's read at a given speed.
public enum PrompterScroll {
    /// Points per second so that `wordCount` words laid out over `scrollableHeight` points take as long as reading
    /// them at `wordsPerMinute` — independent of font size and panel width, which only change the layout.
    public static func pointsPerSecond(scrollableHeight: Double, wordCount: Int, wordsPerMinute: Double) -> Double {
        guard scrollableHeight > 0, wordCount > 0, wordsPerMinute > 0 else { return 0 }
        return scrollableHeight / (Double(wordCount) / wordsPerMinute * 60)
    }

    /// The next scroll offset after `elapsed` seconds, clamped to the script's end.
    public static func advance(_ offset: Double, by elapsed: Double, speed: Double, maxOffset: Double) -> Double {
        min(max(0, offset + speed * elapsed), max(0, maxOffset))
    }
}
