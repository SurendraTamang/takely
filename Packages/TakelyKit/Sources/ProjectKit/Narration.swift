import Foundation

/// A spoken line added to a recording (Demo Mode's narration): an audio file in `narration/`, placed at `t` on the
/// recording timeline. The export mixes these in as their own track; their text becomes the captions when there's
/// no transcript.
public struct NarrationClip: Codable, Sendable, Equatable {
    public var t: Double
    public var duration: Double
    /// File name inside the bundle's `narration/` folder.
    public var file: String
    public var text: String

    public init(t: Double, duration: Double, file: String, text: String) {
        self.t = t
        self.duration = duration
        self.file = file
        self.text = text
    }
}

extension ProjectBundle {
    public var narrationURL: URL { url.appending(path: "narration", directoryHint: .isDirectory) }
    public var narrationIndexURL: URL { url.appending(path: "narration.json") }

    /// No file: no narration.
    public func readNarration() throws -> [NarrationClip] {
        guard FileManager.default.fileExists(atPath: narrationIndexURL.path) else { return [] }
        return try JSONDecoder().decode([NarrationClip].self, from: Data(contentsOf: narrationIndexURL))
    }

    public func write(_ narration: [NarrationClip]) throws {
        try JSONEncoder().encode(narration).write(to: narrationIndexURL, options: .atomic)
    }

    /// The narration as a transcript (one phrase per line), for captions when nothing was transcribed.
    public func narrationTranscript() -> Transcript? {
        guard let clips = try? readNarration(), !clips.isEmpty else { return nil }
        return Transcript(
            locale: Locale.current.identifier,
            phrases: clips.map { Transcript.Phrase(start: $0.t, end: $0.t + $0.duration, text: $0.text, words: []) })
    }
}
