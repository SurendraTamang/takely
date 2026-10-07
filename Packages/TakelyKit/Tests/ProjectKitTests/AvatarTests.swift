import Foundation
import Testing

@testable import ProjectKit

@Suite struct AvatarTests {
    @Test func blinksEveryFewSecondsTheSameEachTime() {
        let samples = stride(from: 0.0, to: 60, by: 0.02).map { AvatarMotion.blink(at: $0) }
        #expect(samples.allSatisfy { (0...1).contains($0) })
        let blinks = zip(samples, samples.dropFirst()).filter { $0 == 0 && $1 > 0 }.count
        #expect((10...20).contains(blinks), "\(blinks) blinks a minute")
        #expect(AvatarMotion.blink(at: 33.3) == AvatarMotion.blink(at: 33.3))
    }

    @Test func voiceLevelsOpenWithSpeechAndCloseInSilence() {
        let speech: [Float] = [0.1, 0.4, 0.5, 0.45, 0.05, 0, 0, 0]
        let levels = VoiceLevels.place([(t: 1, rms: speech)], duration: 3)
        #expect(levels.level(at: 0.5) == 0)
        #expect(levels.level(at: 1 + 2.0 / 30) > 0.5)  // near the loudest moment
        #expect(levels.level(at: 1 + 7.0 / 30) < levels.level(at: 1 + 3.0 / 30))  // closing
        #expect(levels.level(at: 2.5) == 0)
        #expect(VoiceLevels.place([], duration: 2).samples.allSatisfy { $0 == 0 })
    }

    @Test func oneLoudBumpDoesntFlattenTheSpeech() {
        // 3 s of speech at 0.1, one desk bump at 1.0.
        var rms = [Float](repeating: 0.1, count: 90)
        rms[45] = 1
        let voice = VoiceLevels.place([(0, rms)], duration: 3)
        #expect(voice.level(at: 1.0) > 0.8, "speech opens the mouth: \(voice.level(at: 1.0))")
    }
}
