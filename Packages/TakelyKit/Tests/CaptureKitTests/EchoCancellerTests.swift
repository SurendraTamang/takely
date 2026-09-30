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

        var buffers = 0

        mutating func add(_ buffers: [CMSampleBuffer]) throws {
            for buffer in buffers { try add(buffer) }
        }

        mutating func add(_ buffer: CMSampleBuffer) throws {
            buffers += 1
            let index = try EchoCanceller.index(of: buffer.presentationTimeStamp)
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
    /// `monoFrom`: microphone buffers from this chunk on are mono (a different format, like a headset connecting).
    func run(
        far: [Float], mic: [Float], micLead: Int = 0, skipReference: Range<Int>? = nil, monoFrom: Int = .max,
        interleaved: Bool = true
    ) throws -> Collected {
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        let chunks = mic.count / Self.chunk
        for step in 0..<(chunks + micLead) {
            if step < chunks {
                let range = step * Self.chunk..<(step + 1) * Self.chunk
                let buffer =
                    step >= monoFrom
                    ? Synthetic.audio(pts: Self.pts(range.lowerBound), samples: Array(mic[range]), channels: 1)
                    : Synthetic.audio(
                        pts: Self.pts(range.lowerBound), samples: Self.stereo(mic[range]), channels: 2, interleaved: interleaved)
                try out.add(canceller.clean(buffer))
            }
            let r = step - micLead
            if r >= 0, r < chunks {
                let range = r * Self.chunk..<(r + 1) * Self.chunk
                if let skip = skipReference, skip.overlaps(range) { continue }
                canceller.addReference(
                    Synthetic.audio(
                        pts: Self.pts(range.lowerBound), samples: Self.stereo(far[range]), channels: 2, interleaved: interleaved))
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

    @Test func everyMicrophoneSampleComesOutOnceEvenWithJitteryTimestamps() throws {
        // The writer lays audio out by count, so cleaned audio must match the raw microphone sample for sample:
        // small timestamp overlaps and gaps (clock drift) must neither drop nor add samples.
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        for (step, jitter) in [0, -200, 300, -40, 2000, 0].enumerated() {
            let pts = Self.pts(step * 4800 + jitter)
            try out.add(canceller.clean(Synthetic.audio(pts: pts, samples: [Float](repeating: 0.01, count: 4800), channels: 1)))
        }
        try out.add(canceller.flush())
        #expect(out.samples.count == 6 * 4800)
        #expect(out.buffers <= 7)
    }

    @Test func aMicrophoneGapStartsANewRunWithoutFillingIt() throws {
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        try out.add(canceller.clean(Synthetic.audio(pts: Self.pts(0), samples: [Float](repeating: 0.01, count: 4800), channels: 1)))
        // 10 s later (e.g. after a pause): the gap isn't filled, and the output stays as big as the input.
        let later = Self.rate * 10
        try out.add(canceller.clean(Synthetic.audio(pts: Self.pts(later), samples: [Float](repeating: 0.01, count: 4800), channels: 1)))
        try out.add(canceller.flush())
        #expect(out.samples.count == 9600)
        #expect(!out.contiguous)
    }

    @Test func aReferenceThatNeverArrivesStillLetsTheMicrophoneThrough() throws {
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        for step in 0..<50 {
            let samples = [Float](repeating: 0.01, count: Self.chunk)
            try out.add(canceller.clean(Synthetic.audio(pts: Self.pts(step * Self.chunk), samples: samples, channels: 1)))
        }
        // Without any system audio, output lags at most the 150 ms wait plus a frame.
        #expect(
            out.samples.count >= 50 * Self.chunk - Int(EchoCanceller.maxWait) - EchoCanceller.frame - Int(EchoCanceller.processingDelay))
        try out.add(canceller.flush())
        #expect(out.samples.count == 50 * Self.chunk)
    }

    @Test func handlesNonInterleavedAudio() throws {
        let far = Self.noise(count: Self.chunk * 300)
        let mic = Self.echoOf(far)
        let out = try run(far: far, mic: mic, interleaved: false)
        #expect(out.samples.count == mic.count)
        let erle = Self.erle(mic, out.samples, from: Self.rate * 3)
        #expect(erle >= 25, "ERLE \(erle) dB")
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

    @Test func keepsCancellingWhenTheMicrophoneFormatChanges() throws {
        // Halfway through, the microphone switches from stereo to mono (e.g. a headset connects).
        let far = Self.noise(count: Self.chunk * 400)
        let mic = Self.echoOf(far)
        let out = try run(far: far, mic: mic, monoFrom: 200)
        #expect(out.samples.count == mic.count)
        let erle = Self.erle(mic, out.samples, from: Self.chunk * 200 + Self.rate * 3)
        #expect(erle >= 25, "ERLE after the switch \(erle) dB")
    }

    @Test func followsAMicrophoneClockThatDrifts() throws {
        // The microphone's clock runs 0.2 % slow against the host: each of its samples spans a little more host
        // time, so its timestamps drift ~100 ms from its sample count over 50 s. The echo it hears must still be
        // matched with the system audio playing at the same host time.
        let drift = 0.002
        let count = Self.rate * 50
        let far = Self.noise(count: Int(Double(count) * (1 + drift)) + Self.chunk)
        let mic = (0..<count).map { k -> Float in
            let host = Int((Double(k) * (1 + drift)).rounded()) - 1440
            return host >= 0 ? far[host] * 0.5 : 0
        }
        let canceller = try #require(EchoCanceller())
        var out = Collected()
        var reference = 0
        for step in 0..<(count / Self.chunk) {
            let first = step * Self.chunk
            let micPTS = Synthetic.seconds(Self.base + Double(first) * (1 + drift) / Double(Self.rate))
            while reference * Self.chunk <= Int(Double(first + Self.chunk) * (1 + drift)) {
                let range = reference * Self.chunk..<(reference + 1) * Self.chunk
                canceller.addReference(Synthetic.audio(pts: Self.pts(range.lowerBound), samples: Self.stereo(far[range]), channels: 2))
                reference += 1
            }
            let range = first..<first + Self.chunk
            try out.add(canceller.clean(Synthetic.audio(pts: micPTS, samples: Self.stereo(mic[range]), channels: 2)))
        }
        try out.add(canceller.flush())
        #expect(out.samples.count == count / Self.chunk * Self.chunk)
        let erle = Self.erle(Array(mic.prefix(out.samples.count)), out.samples, from: Self.rate * 40)
        #expect(erle >= 20, "ERLE after 40 s of drift \(erle) dB")
    }

    @Test func rejectsInvalidTimestamps() {
        #expect(throws: EchoCanceller.Failure.invalidTime) { try EchoCanceller.index(of: .invalid) }
        #expect(throws: EchoCanceller.Failure.invalidTime) { try EchoCanceller.index(of: .positiveInfinity) }
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
