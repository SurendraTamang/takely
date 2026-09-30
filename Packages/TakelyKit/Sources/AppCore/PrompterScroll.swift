/// Teleprompter pacing: how far the script moves per second at a reading speed.
public enum PrompterScroll {
    /// Points per second for `wordsPerMinute` at `fontSize`, assuming ~6 words per line and a line height of
    /// 1.3 × the font size (a comfortable reading layout at the prompter's width).
    public static func pointsPerSecond(wordsPerMinute: Double, fontSize: Double) -> Double {
        let linesPerSecond = wordsPerMinute / 60 / 6
        return linesPerSecond * fontSize * 1.3
    }

    /// The next scroll offset after `elapsed` seconds, clamped to the script's end.
    public static func advance(_ offset: Double, by elapsed: Double, speed: Double, maxOffset: Double) -> Double {
        min(max(0, offset + speed * elapsed), max(0, maxOffset))
    }
}
