import Foundation
import Testing

@testable import ProjectKit

@Suite struct TranscriptTests {
    /// A phrase whose words are 0.5 s apart.
    static func phrase(_ text: String, at start: Double) -> Transcript.Phrase {
        let words = text.split(separator: " ").enumerated().map { i, word in
            Transcript.Word(start: start + Double(i) * 0.5, end: start + Double(i) * 0.5 + 0.4, text: String(word))
        }
        return Transcript.Phrase(start: start, end: words.last!.end, text: text, words: words)
    }

    @Test func shortPhrasesAreOneCue() {
        let transcript = Transcript(locale: "en_US", phrases: [Self.phrase("Hello there everyone", at: 1)])
        #expect(transcript.cues() == [CaptionCue(start: 1, end: 2.4, text: "Hello there everyone")])
    }

    @Test func longPhrasesWrapToTwoLinesThenStartANewCue() {
        let text = "This is a much longer sentence that keeps going well past what fits on two short caption lines today"
        let cues = Transcript(locale: "en_US", phrases: [Self.phrase(text, at: 0)]).cues(lineLength: 20, maxLines: 2, maxDuration: 60)
        #expect(cues.count > 1)
        for cue in cues {
            let lines = cue.text.split(separator: "\n")
            #expect(lines.count <= 2 && lines.allSatisfy { $0.count <= 20 }, "\(cue.text)")
        }
        #expect(cues.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " ") == text)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func cuesStayUnderTheMaximumDuration() {
        let text = (1...30).map { "w\($0)" }.joined(separator: " ")  // 15 s of words
        let cues = Transcript(locale: "en_US", phrases: [Self.phrase(text, at: 0)]).cues(maxDuration: 6)
        #expect(cues.allSatisfy { $0.end - $0.start <= 6 })
    }

    @Test func phrasesWithoutWordTimingsStillCaption() {
        let phrase = Transcript.Phrase(start: 2, end: 4, text: "No word times", words: [])
        #expect(Transcript(locale: "en_US", phrases: [phrase]).cues() == [CaptionCue(start: 2, end: 4, text: "No word times")])
    }

    @Test func webVTTFormatsTimesAndCues() {
        let vtt = WebVTT.render([
            CaptionCue(start: 1.5, end: 3.25, text: "Hello"),
            CaptionCue(start: 3661.004, end: 3662, text: "Line one\nLine two"),
        ])
        #expect(vtt == "WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello\n\n01:01:01.004 --> 01:01:02.000\nLine one\nLine two\n")
    }

    @Test func titleAndSummaryAreOptionalInOldManifests() throws {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 2, height: 2), fps: 30, codec: .h264),
            camera: .init(enabled: false))
        var json = try JSONSerialization.jsonObject(with: project.encoded()) as! [String: Any]
        json.removeValue(forKey: "title")
        let decoded = try Project.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded.title == nil && decoded.summary == nil)
    }

    @Test func languagesWithoutSpacesJoinDirectlyAndWrapByCharacter() {
        let words = ["今日は", "新しい", "機能を", "紹介", "します"].enumerated().map {
            Transcript.Word(start: Double($0.offset), end: Double($0.offset) + 0.9, text: $0.element)
        }
        let transcript = Transcript(
            locale: "ja_JP", phrases: [.init(start: 0, end: 4.9, text: words.map(\.text).joined(), words: words)])
        #expect(transcript.text == "今日は新しい機能を紹介します")
        #expect(transcript.cues() == [CaptionCue(start: 0, end: 4.9, text: "今日は新しい機能を紹介します")])
        #expect(Transcript.wrap(words.map(\.text), width: 7, separator: "") == ["今日は新しい", "機能を紹介", "します"])
        // A phrase without word times breaks anywhere, over cues of two 16-character lines.
        let long = String(repeating: "あ", count: 40)
        let cues = Transcript(locale: "zh_CN", phrases: [.init(start: 0, end: 5, text: long, words: [])]).cues()
        #expect(
            cues.map(\.text) == [
                String(repeating: "あ", count: 16) + "\n" + String(repeating: "あ", count: 16), String(repeating: "あ", count: 8),
            ])
        #expect(cues.map(\.start) == [0, 4])
        #expect(!Transcript.writtenWithoutSpaces("en_US") && Transcript.writtenWithoutSpaces("th"))
    }
}
