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

    public var text: String { phrases.map(\.text).joined(separator: separator) }

    /// Whether `locale`'s language is written without spaces between words (Chinese, Japanese, Thai, Lao, Khmer,
    /// Burmese): its words and phrases are joined directly, and lengths are counted in characters.
    public static func writtenWithoutSpaces(_ locale: String) -> Bool {
        ["zh", "ja", "th", "lo", "km", "my"].contains(Locale(identifier: locale).language.languageCode?.identifier ?? "")
    }

    /// What goes between words and phrases: a space, or nothing for languages written without spaces.
    public var separator: String { Self.writtenWithoutSpaces(locale) ? "" : " " }

    /// Caption cues: each phrase split at word boundaries into cues of at most `maxLines` lines of `lineLength`
    /// characters and `maxDuration` seconds. The default line is 42 characters (the common broadcast/web guideline),
    /// or 16 for languages without spaces, whose characters are full width (Netflix uses 16 for Chinese, 13 for Japanese).
    public func cues(lineLength: Int? = nil, maxLines: Int = 2, maxDuration: Double = 6) -> [CaptionCue] {
        let separator = separator
        let lineLength = lineLength ?? (separator.isEmpty ? 16 : 42)
        var cues: [CaptionCue] = []
        for phrase in phrases {
            let words = phrase.words.isEmpty ? Self.pieces(of: phrase, width: separator.isEmpty ? lineLength : nil) : phrase.words
            var current: [Word] = []
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                let lines = Self.wrap(current.map(\.text), width: lineLength, separator: separator)
                cues.append(CaptionCue(start: first.start, end: last.end, text: lines.joined(separator: "\n")))
                current = []
            }
            for word in words {
                if let first = current.first,
                    Self.wrap((current + [word]).map(\.text), width: lineLength, separator: separator).count > maxLines
                        || word.end - first.start > maxDuration
                {
                    flush()
                }
                current.append(word)
            }
            flush()
        }
        return cues
    }

    /// A phrase without word timings as one word — or, when `width` is given (no spaces: it can break anywhere), as
    /// pieces of `width` characters with times shared out by length, so it spreads over cues instead of one tall one.
    static func pieces(of phrase: Phrase, width: Int?) -> [Word] {
        guard let width, phrase.text.count > width else { return [Word(start: phrase.start, end: phrase.end, text: phrase.text)] }
        let count = Double(phrase.text.count)
        let length = phrase.end - phrase.start
        return stride(from: 0, to: phrase.text.count, by: width).map { offset in
            let end = min(offset + width, phrase.text.count)
            return Word(
                start: phrase.start + length * Double(offset) / count, end: phrase.start + length * Double(end) / count,
                text: String(phrase.text.dropFirst(offset).prefix(width)))
        }
    }

    /// Greedy word wrap; a word longer than `width` gets a line of its own. Without a separator (no spaces), a
    /// line can break anywhere, so a long word (e.g. a phrase without word timings) is split into lines of `width`.
    static func wrap(_ words: [String], width: Int, separator: String = " ") -> [String] {
        var lines: [String] = []
        let words =
            separator.isEmpty
            ? words.flatMap { word in stride(from: 0, to: word.count, by: width).map { String(word.dropFirst($0).prefix(width)) } }
            : words
        for word in words {
            if let last = lines.last, last.count + separator.count + word.count <= width {
                lines[lines.count - 1] = last + separator + word
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
