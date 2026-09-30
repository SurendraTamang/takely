import CoreMedia
import Foundation
import TestSupport
import Testing

@testable import CaptureKit

@Suite struct EchoCancellerTests {
    static let rate = 48_000
    static let chunk = 1024
    static let base = 1000.0

    /// Deterministic noise-like signal in [-0.5, 0.5].
    static func noise(count: Int, seed: UInt32 = 12345) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
    }

    static func tone(count: Int, hz: Double = 440, amplitude: Float = 0.1) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / Double(rate))) }
    }

    static func power<C: Collection>(_ x: C) -> Double where C.Element == Float {
        x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
    }

    static func stereo(_ mono: ArraySlice<Float>) -> [Float] { mono.flatMap { [$0, $0] } }

    static func pts(_ sample: Int, rate: Int = rate) -> CMTime { Synthetic.seconds(base + Double(sample) / Double(rate)) }

    /// Cleaned output concatenated on a sample timeline starting at `base`, plus whether it had gaps or overlaps.
    struct Collected {
        var samples: [Float] = []
        var contiguous = true
        var nextIndex: Int64?

        mutating func add(_ buffer: CMSampleBuffer?) throws {
            guard let buffer else { return }
            let index = Int64((buffer.presentationTimeStamp.seconds * Double(EchoCancellerTests.rate)).rounded())
            if let nextIndex, index != nextIndex { contiguous = false }
            let values = try EchoCancellerTests.floats(buffer)
            samples += values
            nextIndex = index + Int64(values.count)
        }
    }

    static func floats(_ buffer: CMSampleBuffer) throws -> [Float] {
        let block = try #require(buffer.dataBuffer)
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        values.withUnsafeMutableBytes {
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        #expect(buffer.numSamples == values.count, "mono output")
        return values
    }

    /// Feeds `far` as stereo system audio and `mic` as stereo microphone audio in `chunk`-sized buffers,
    /// the microphone `micLead` buffers ahead of the reference, and returns the cleaned microphone.
    func run(far: [Float], mic: [Float], micLead: Int = 0, skipReference: Range<Int>? = nil) throws -> Collected {
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        let chunks = mic.count / Self.chunk
        for step in 0..<(chunks + micLead) {
            if step < chunks {
                let range = step * Self.chunk..<(step + 1) * Self.chunk
                try out.add(
                    canceller.clean(Synthetic.audio(pts: Self.pts(range.lowerBound), samples: Self.stereo(mic[range]), channels: 2)))
            }
            let r = step - micLead
            if r >= 0, r < chunks {
                let range = r * Self.chunk..<(r + 1) * Self.chunk
                if let skip = skipReference, skip.overlaps(range) { continue }
                try canceller.addReference(Synthetic.audio(pts: Self.pts(range.lowerBound), samples: Self.stereo(far[range]), channels: 2))
            }
        }
        try out.add(canceller.flush())
        return out
    }

    static func echoOf(_ far: [Float], delay: Int = 1440, gain: Float = 0.5) -> [Float] {
        (0..<far.count).map { $0 >= delay ? far[$0 - delay] * gain : 0 }
    }

    static func erle(_ mic: [Float], _ out: [Float], from: Int) -> Double {
        10 * log10(power(mic[from...]) / max(power(out[from..<min(out.count, mic.count)]), 1e-20))
    }

    @Test func removesTheEchoOfTheSystemAudio() throws {
        let far = Self.noise(count: Self.chunk * 400)  // ~8.5 s
        let mic = Self.echoOf(far)
        let out = try run(far: far, mic: mic)
        #expect(out.contiguous)
        #expect(out.samples.count == mic.count)
        let erle = Self.erle(mic, out.samples, from: Self.rate * 3)
        #expect(erle >= 25, "ERLE \(erle) dB")
    }

    @Test func keepsTheVoiceWhenNothingPlays() throws {
        let count = Self.chunk * 200
        let voice = Self.tone(count: count)
        let out = try run(far: [Float](repeating: 0, count: count), mic: voice)
        let change = 10 * log10(Self.power(out.samples[Self.rate...]) / Self.power(voice[Self.rate...]))
        #expect(abs(change) < 1, "voice level change \(change) dB")
    }

    @Test func waitsForAReferenceThatArrivesLate() throws {
        let far = Self.noise(count: Self.chunk * 400)
        let mic = Self.echoOf(far)
        // The microphone runs 5 buffers (~107 ms) ahead of the system audio.
        let out = try run(far: far, mic: mic, micLead: 5)
        let erle = Self.erle(mic, out.samples, from: Self.rate * 3)
        #expect(erle >= 25, "ERLE \(erle) dB")
    }

    @Test func survivesAGapInTheReference() throws {
        let far = Self.noise(count: Self.chunk * 300)
        let mic = Self.echoOf(far)
        let gap = Self.rate * 2..<Self.rate * 2 + Self.rate * 3 / 10  // 300 ms of missing system audio
        let out = try run(far: far, mic: mic, skipReference: gap)
        #expect(out.contiguous)
        #expect(out.samples.count == mic.count)
    }

    @Test func resamplesA44kStereoMicrophone() throws {
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        let micRate = 44_100
        for step in 0..<100 {
            let samples = [Float](repeating: 0.01, count: 441 * 2)  // 10 ms stereo
            try out.add(
                canceller.clean(
                    Synthetic.audio(pts: Self.pts(step * 441, rate: micRate), samples: samples, channels: 2, sampleRate: 44_100)))
        }
        try out.add(canceller.flush())
        #expect(abs(out.samples.count - Self.rate) <= 64, "1 s of 44.1 kHz became \(out.samples.count) samples at 48 kHz")
    }

    @Test func overlappingMicrophoneBuffersDontRepeatAudio() throws {
        // The second buffer claims to start 200 samples before the first one ends.
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        try out.add(canceller.clean(Synthetic.audio(pts: Self.pts(0), samples: [Float](repeating: 0.01, count: 4800), channels: 1)))
        try out.add(canceller.clean(Synthetic.audio(pts: Self.pts(4600), samples: [Float](repeating: 0.01, count: 4800), channels: 1)))
        try out.add(canceller.flush())
        #expect(out.contiguous)
        #expect(out.samples.count == 9400)
    }

    @Test func largeBuffersKeepExactSampleCounts() throws {
        // 8192-frame buffers (seen when reading recordings back) must not lose or gain samples.
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        for step in 0..<20 {
            let samples = [Float](repeating: 0.01, count: 8192 * 2)
            try out.add(canceller.clean(Synthetic.audio(pts: Self.pts(step * 8192), samples: samples, channels: 2)))
        }
        try out.add(canceller.flush())
        #expect(out.contiguous)
        #expect(out.samples.count == 8192 * 20)
    }

    @Test func aChangedMicrophoneFormatThrows() throws {
        let canceller = try #require(EchoCanceller())
        _ = try canceller.clean(Synthetic.audio(pts: Self.pts(0), samples: [Float](repeating: 0, count: 2048), channels: 2))
        #expect(throws: EchoCanceller.Failure.formatChanged) {
            try canceller.clean(Synthetic.audio(pts: Self.pts(1024), samples: [Float](repeating: 0, count: 1024), channels: 1))
        }
    }

    @Test func outputIsNotDelayed() throws {
        // A click in the microphone with silent system audio must come out at the same timestamp.
        var mic = [Float](repeating: 0, count: Self.chunk * 100)
        let click = Self.rate
        for i in click..<click + 48 { mic[i] = 0.5 }
        let out = try run(far: [Float](repeating: 0, count: mic.count), mic: mic)
        let peak = try #require(out.samples.indices.max { abs(out.samples[$0]) < abs(out.samples[$1]) })
        #expect(abs(peak - click) <= 48, "click moved from \(click) to \(peak)")
    }
}
