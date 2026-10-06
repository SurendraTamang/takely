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

    /// A resampled microphone can stamp a buffer a little before the end of the previous one: a pause in progress
    /// must survive it.
    @Test func timestampsThatStepBackDontLoseAPause() {
        let samples = Self.audio([(1, true), (0.6, false), (1, true)])
        var detector = SilenceDetector()
        for (n, chunk) in stride(from: 0, to: samples.count, by: 1024).enumerated() {
            let jitter = n % 3 == 2 ? -0.3 : 0  // every third buffer stamped 300 ms early
            detector.add(Array(samples[chunk..<min(chunk + 1024, samples.count)]), at: Double(chunk) / Double(Self.rate) + jitter)
        }
        #expect(detector.gaps.count == 1, "gaps \(detector.gaps)")
        if let gap = detector.gaps.first { #expect(abs(gap.lowerBound - 1) < 0.05 && abs(gap.upperBound - 1.6) < 0.05, "gap \(gap)") }
    }

    @Test func cutsBackToThePauseBeforeTheLastWords() {
        // "…first take. [pause] Second tak— oops" → cut inside the pause, keeping 0.2 s of it.
        let detector = Self.detect(Self.audio([(2, true), (1, false), (1.5, true)]), start: 10)
        #expect(abs(detector.cutPoint(segmentStart: 10, now: 14.5) - 12.2) < 0.02)
    }

    @Test func ignoresTheSilenceStillGoingWhenOopsIsPressed() {
        // Said something wrong, stopped, then pressed oops: the trailing silence isn't the cut; the pause before is.
        let detector = Self.detect(Self.audio([(1, true), (0.5, false), (1, true), (2, false)]))
        #expect(abs(detector.cutPoint(segmentStart: 0, now: 4.5) - 1.2) < 0.02)
    }

    @Test func shortPausesKeepAtMostHalfTheGap() {
        let detector = Self.detect(Self.audio([(1, true), (0.4, false), (1, true)]))
        #expect(abs(detector.cutPoint(segmentStart: 0, now: 2.4) - 1.2) < 0.02)
    }

    @Test func withoutARecentPauseItCutsBackFiveSecondsAtMost() {
        // No pause in the segment (e.g. the mic is off, or speakers play throughout): 5 s back, never past the start.
        #expect(Self.detect(Self.audio([(30, true)])).cutPoint(segmentStart: 0, now: 30) == 25)
        #expect(Self.detect(Self.audio([(3, true)])).cutPoint(segmentStart: 0, now: 3) == 0)
        #expect(SilenceDetector().cutPoint(segmentStart: 40, now: 60) == 55)
    }

    @Test func pausesBeforeTheSegmentOrTooLongAgoDontCount() {
        let detector = Self.detect(Self.audio([(1, true), (0.6, false), (29, true)]))
        #expect(detector.cutPoint(segmentStart: 2, now: 6) == 2)  // the pause is before this segment
        #expect(detector.cutPoint(segmentStart: 0, now: 30.6) == 25.6)  // the pause is 29 s ago: past the 15 s lookback
    }

    @Test func dropsGapsAfterACut() {
        var detector = Self.detect(Self.audio([(1, true), (0.6, false), (1, true), (0.6, false), (1, true)]))
        #expect(detector.gaps.count == 2)
        detector.discard(from: 2)
        #expect(detector.gaps.count == 1)
    }
}
