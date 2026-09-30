import Foundation
import Testing

@testable import CaptureKit

@Suite struct SilenceDetectorTests {
    static let rate = 48_000

    /// `pattern` of (seconds, speaking?) → samples: speech is a loud tone, silence is faint noise (−60 dBFS).
    static func audio(_ pattern: [(Double, Bool)]) -> [Float] {
        var samples: [Float] = []
        for (seconds, speaking) in pattern {
            for i in 0..<Int(seconds * Double(rate)) {
                let quiet: Float = i % 2 == 0 ? 0.001 : -0.001
                samples.append(speaking ? 0.2 * Float(sin(Double(i) * 0.05)) : quiet)
            }
        }
        return samples
    }

    /// Feeds `samples` in 1024-sample buffers starting at edited time `start`.
    static func detect(_ samples: [Float], start: Double = 0) -> SilenceDetector {
        var detector = SilenceDetector()
        for chunk in stride(from: 0, to: samples.count, by: 1024) {
            detector.add(Array(samples[chunk..<min(chunk + 1024, samples.count)]), at: start + Double(chunk) / Double(rate))
        }
        return detector
    }

    @Test func findsSilencesOfAtLeast400ms() {
        let detector = Self.detect(Self.audio([(1, true), (0.6, false), (1, true), (0.3, false), (1, true)]))
        #expect(detector.gaps.count == 1)
        let gap = try! #require(detector.gaps.first)
        #expect(abs(gap.lowerBound - 1) < 0.02 && abs(gap.upperBound - 1.6) < 0.02, "gap \(gap)")
    }

    @Test func cutsBackToThePauseBeforeTheLastWords() {
        // "…first take. [pause] Second tak— oops" → cut inside the pause, keeping 0.2 s of it.
        let detector = Self.detect(Self.audio([(2, true), (1, false), (1.5, true)]), start: 10)
        #expect(abs(detector.cutPoint(segmentStart: 10) - 12.2) < 0.02)
    }

    @Test func ignoresTheSilenceStillGoingWhenOopsIsPressed() {
        // Said something wrong, stopped, then pressed oops: the trailing silence isn't the cut; the pause before is.
        let detector = Self.detect(Self.audio([(1, true), (0.5, false), (1, true), (2, false)]))
        #expect(abs(detector.cutPoint(segmentStart: 0) - 1.2) < 0.02)
    }

    @Test func shortPausesKeepAtMostHalfTheGap() {
        let detector = Self.detect(Self.audio([(1, true), (0.4, false), (1, true)]))
        #expect(abs(detector.cutPoint(segmentStart: 0) - 1.2) < 0.02)
    }

    @Test func withoutAPauseInTheSegmentItCutsToTheSegmentStart() {
        let detector = Self.detect(Self.audio([(1, true), (0.6, false), (3, true)]))
        #expect(detector.cutPoint(segmentStart: 2) == 2)
        #expect(Self.detect(Self.audio([(3, true)])).cutPoint(segmentStart: 0) == 0)
    }

    @Test func dropsGapsAfterACut() {
        var detector = Self.detect(Self.audio([(1, true), (0.6, false), (1, true), (0.6, false), (1, true)]))
        #expect(detector.gaps.count == 2)
        detector.discard(from: 2)
        #expect(detector.gaps.count == 1)
    }
}
