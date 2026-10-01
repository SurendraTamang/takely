import Foundation

/// What was said, on the edited timeline (`transcript.json`): phrases with their words.
public struct Transcript: Codable, Sendable, Equatable {
    public struct Word: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct Phrase: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
        /// Empty when the recognizer gave no word timings.
        public var words: [Word]

        public init(start: Double, end: Double, text: String, words: [Word]) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
        }
    }

    /// The recognizer's locale identifier, e.g. "en_US".
    public var locale: String
    public var phrases: [Phrase]

    public init(locale: String, phrases: [Phrase]) {
        self.locale = locale
        self.phrases = phrases
    }

    public var text: String { phrases.map(\.text).joined(separator: " ") }

    /// Caption cues: each phrase split at word boundaries into cues of at most `maxLines` lines of `lineLength`
    /// characters and `maxDuration` seconds (the common broadcast/web guideline is 2 × 42 characters).
    public func cues(lineLength: Int = 42, maxLines: Int = 2, maxDuration: Double = 6) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        for phrase in phrases {
            let words = phrase.words.isEmpty ? [Word(start: phrase.start, end: phrase.end, text: phrase.text)] : phrase.words
            var current: [Word] = []
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                let lines = Self.wrap(current.map(\.text), width: lineLength)
                cues.append(CaptionCue(start: first.start, end: last.end, text: lines.joined(separator: "\n")))
                current = []
            }
            for word in words {
                if let first = current.first,
                    Self.wrap((current + [word]).map(\.text), width: lineLength).count > maxLines || word.end - first.start > maxDuration
                {
                    flush()
                }
                current.append(word)
            }
            flush()
        }
        return cues
    }

    /// Greedy word wrap; a word longer than `width` gets a line of its own.
    static func wrap(_ words: [String], width: Int) -> [String] {
        var lines: [String] = []
        for word in words {
            if let last = lines.last, last.count + 1 + word.count <= width {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines
    }
}

/// One caption on screen from `start` to `end` (seconds); `text` may contain line breaks.
public struct CaptionCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// WebVTT (W3C) caption files, for web players, YouTube and editors.
public enum WebVTT {
    public static func render(_ cues: [CaptionCue]) -> String {
        "WEBVTT\n" + cues.map { "\n\(time($0.start)) --> \(time($0.end))\n\($0.text)\n" }.joined()
    }

    static func time(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
