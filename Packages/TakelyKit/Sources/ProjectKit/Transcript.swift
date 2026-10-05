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

    /// How a language's lines break: at spaces; anywhere (Chinese, Japanese: full-width characters); or at word
    /// boundaries found from a dictionary (Thai, Lao, Khmer, Burmese: no spaces, but words mustn't be split).
    enum LineBreaks { case spaces, anywhere, dictionaryWords }

    static func lineBreaks(_ locale: String) -> LineBreaks {
        switch Locale(identifier: locale).language.languageCode?.identifier ?? "" {
        case "zh", "ja", "yue": .anywhere
        case "th", "lo", "km", "my": .dictionaryWords
        default: .spaces
        }
    }

    /// Whether `locale`'s language is written without spaces between words: its words and phrases are joined directly.
    public static func writtenWithoutSpaces(_ locale: String) -> Bool { lineBreaks(locale) != .spaces }

    /// What goes between words and phrases: a space, or nothing for languages written without spaces.
    public var separator: String { Self.writtenWithoutSpaces(locale) ? "" : " " }

    /// Caption cues: each phrase split at word boundaries into cues of at most `maxLines` lines of `lineLength`
    /// characters and `maxDuration` seconds. The default line is 42 characters (the common broadcast/web guideline),
    /// 16 for Chinese and Japanese (full-width characters; Netflix uses 16 and 13) and 35 for Thai and its neighbours.
    public func cues(lineLength: Int? = nil, maxLines: Int = 2, maxDuration: Double = 6) -> [CaptionCue] {
        let breaks = Self.lineBreaks(locale)
        let lineLength = max(1, lineLength ?? [.spaces: 42, .anywhere: 16, .dictionaryWords: 35][breaks]!)
        let wrap = { (words: [Word]) in Self.wrap(words.map(\.text), width: lineLength, breaks: breaks) }
        var cues: [CaptionCue] = []
        for phrase in phrases {
            let words = phrase.words.isEmpty ? Self.pieces(of: phrase, width: lineLength, breaks: breaks) : phrase.words
            var current: [Word] = []
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                cues.append(CaptionCue(start: first.start, end: last.end, text: wrap(current).joined(separator: "\n")))
                current = []
            }
            for word in words {
                if let first = current.first, wrap(current + [word]).count > maxLines || word.end - first.start > maxDuration {
                    flush()
                }
                current.append(word)
            }
            flush()
        }
        return cues
    }

    /// A phrase without word timings as one word — or, in a language without spaces, as line-sized pieces with times
    /// shared out by length, so it spreads over cues instead of making one tall one.
    static func pieces(of phrase: Phrase, width: Int, breaks: LineBreaks) -> [Word] {
        guard breaks != .spaces, phrase.text.count > width else { return [Word(start: phrase.start, end: phrase.end, text: phrase.text)] }
        let count = Double(phrase.text.count)
        let length = phrase.end - phrase.start
        var offset = 0
        return split(phrase.text, width: width, breaks: breaks).map { piece in
            defer { offset += piece.count }
            return Word(
                start: phrase.start + length * Double(offset) / count, end: phrase.start + length * Double(offset + piece.count) / count,
                text: piece)
        }
    }

    /// Greedy word wrap; a word longer than `width` gets a line of its own. In a language without spaces, words are
    /// joined directly and a long one is split where that language may break.
    static func wrap(_ words: [String], width: Int, breaks: LineBreaks = .spaces) -> [String] {
        let width = max(1, width)
        let separator = breaks == .spaces ? " " : ""
        let words = breaks == .spaces ? words : words.flatMap { split($0, width: width, breaks: breaks) }
        var lines: [String] = []
        for word in words {
            if let last = lines.last, last.count + separator.count + word.count <= width {
                lines[lines.count - 1] = last + separator + word
            } else {
                lines.append(word)
            }
        }
        return lines
    }

    /// `text` in pieces of at most `width` characters, broken where the language allows (a single unbreakable word
    /// longer than that stays whole).
    static func split(_ text: String, width: Int, breaks: LineBreaks) -> [String] {
        guard text.count > width else { return [text] }
        var pieces: [String] = []
        for unit in units(text, breaks: breaks) {
            if let last = pieces.last, last.count + unit.count <= width {
                pieces[pieces.count - 1] = last + unit
            } else {
                pieces.append(unit)
            }
        }
        return pieces
    }

    /// The smallest pieces a line may break between: characters, or dictionary words (with what follows them, so the
    /// pieces put back together give `text`).
    static func units(_ text: String, breaks: LineBreaks) -> [String] {
        guard breaks == .dictionaryWords else { return text.map(String.init) }
        var starts: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.lowerBound)
        }
        let bounds = [text.startIndex] + starts.filter { $0 > text.startIndex } + [text.endIndex]
        return zip(bounds, bounds.dropFirst()).map { String(text[$0..<$1]) }
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
