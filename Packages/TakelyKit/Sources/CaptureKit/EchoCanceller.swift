@preconcurrency import AVFoundation
import CoreMedia
import OSLog
import WebRTCAEC

/// Removes speaker playback from the microphone with WebRTC AEC3, using the system audio as the echo reference.
///
/// The writer lays audio out by sample count (only a track's first timestamp counts), so the cleaned microphone
/// must contain exactly the raw microphone's samples: one output sample per input sample, in order. The reference
/// is placed by host-clock timestamps; the microphone follows its sample count, and the difference between the two
/// (its clock drift, `skew`) is tracked so each microphone frame meets the system audio played at the same host
/// time. Only a jump over `micGap` (e.g. a pause) starts a new run. Nothing here throws mid-recording: an unreadable
/// system-audio buffer is skipped and an unreadable microphone buffer becomes silence of the same length.
/// Not thread-safe: `FrameRouter` calls it under a lock (ScreenCaptureKit delivers both streams on one queue).
final class EchoCanceller {
    enum Failure: Error, Equatable {
        case conversion
        case invalidTime
    }

    static let sampleRate = 48_000
    /// AEC3 works on 10 ms frames.
    static let frame = sampleRate / 100
    /// How far the microphone may run ahead of its reference before the missing part counts as silence.
    static let maxWait = Int64(sampleRate * 150 / 1000)
    /// Reference timestamp jitter absorbed without treating it as a gap or an overlap.
    static let tolerance = Int64(sampleRate / 1000)
    /// For resampled streams, whose converter holds samples back: only a jump this big is a real gap.
    static let resampledTolerance = Int64(sampleRate / 5)
    /// A microphone jump this big is a real gap (a pause); smaller ones are clock drift and are ignored.
    static let micGap = Int64(sampleRate / 10)
    /// System audio kept when the microphone stalls, so the reference can't grow without bound.
    static let maxReference = sampleRate * 2
    /// AEC3's output lags its input by this many samples (its band-splitting filter bank; measured, constant).
    static let processingDelay = Int64(430)

    private let aec: OpaquePointer
    private let outputFormat: CMAudioFormatDescription
    private var referenceConverter: Downmixer?
    private var micConverter: Downmixer?
    private var reference = Timeline()
    private var mic = Timeline()
    private var run: Run?
    /// Microphone timestamp minus its sample-count position (smoothed): where its frames sit in host time.
    private var skew: Int64 = 0
    /// Set when AEC3 fails: the microphone then passes through unprocessed, sample for sample.
    private var bypassing = false
    private static let log = Logger(subsystem: "app.takely", category: "capture")

    /// Nil if AEC3 can't be created.
    init?() {
        guard let aec = webrtc_aec_create(Int32(Self.sampleRate)), let format = Self.makeOutputFormat() else { return nil }
        self.aec = aec
        self.outputFormat = format
    }

    deinit { webrtc_aec_destroy(aec) }

    /// Adds system audio (the far end) to the reference timeline. An unreadable buffer is skipped (a gap).
    func addReference(_ buffer: CMSampleBuffer) {
        guard let index = try? Self.index(of: buffer.presentationTimeStamp) else { return }
        if let format = buffer.formatDescription, referenceConverter?.handles(format) == false { referenceConverter = nil }
        guard let samples = try? Downmixer.convert(buffer, with: &referenceConverter) else { return }
        let tolerance = referenceConverter?.exact == false ? Self.resampledTolerance : Self.tolerance
        if reference.samples.isEmpty || index < reference.start || index > reference.end + Int64(Self.maxReference) {
            reference = Timeline(start: index)
        } else if index > reference.end + tolerance {
            reference.samples += [Float](repeating: 0, count: Int(index - reference.end))  // a gap in the playback is silence
        } else if index < reference.end - tolerance {
            reference.samples += samples.dropFirst(Int(reference.end - index))  // already have this part
            return trimReference()
        }
        reference.samples += samples
        trimReference()
    }

    private func trimReference() {
        if reference.samples.count > Self.maxReference { reference.removeFirst(reference.samples.count - Self.maxReference) }
    }

    /// Adds microphone audio and returns what is ready: 48 kHz mono, echo removed, one buffer per run.
    func clean(_ buffer: CMSampleBuffer) -> [CMSampleBuffer] {
        var output = Output()
        var converter = micConverter
        if let format = buffer.formatDescription, converter?.handles(format) == false { converter = nil }  // e.g. a headset
        let converted = try? Downmixer.convert(buffer, with: &converter)
        if converter !== micConverter {
            drain(force: true, into: &output)  // the format changed: finish the run in the old one
            micConverter = converter
        }
        let samples = converted ?? [Float](repeating: 0, count: buffer.numSamples)  // unreadable: keep its length
        let expected = mic.end + skew
        if let index = try? Self.index(of: buffer.presentationTimeStamp), run != nil || !mic.samples.isEmpty {
            if index > expected + Self.micGap || index < expected - Self.micGap {
                drain(force: true, into: &output)  // a gap in the microphone (e.g. after a pause) starts a new run
                mic = Timeline(start: index)
            } else {
                skew += (index - mic.end - skew) / 16  // follow the microphone clock's drift, ignoring jitter
            }
        } else if run == nil && mic.samples.isEmpty {
            mic = Timeline(start: (try? Self.index(of: buffer.presentationTimeStamp)) ?? mic.end)
        }
        mic.samples += samples
        drain(force: false, into: &output)
        return output.buffers(format: outputFormat)
    }

    /// Processes all pending microphone audio (missing reference counts as silence) and ends the run.
    func flush() -> [CMSampleBuffer] {
        var output = Output()
        drain(force: true, into: &output)
        return output.buffers(format: outputFormat)
    }

    /// Processes pending microphone frames whose reference has arrived (or waited long enough).
    /// `force` processes everything and ends the run, pushing AEC3's delayed tail out.
    private func drain(force: Bool, into output: inout Output) {
        while mic.samples.count >= Self.frame || (force && !mic.samples.isEmpty) {
            let start = mic.start
            let referenceReady = reference.end >= start + skew + Int64(Self.frame)
            guard force || referenceReady || mic.end - start >= Self.maxWait else { return }
            let count = min(Self.frame, mic.samples.count)
            let near = Array(mic.samples.prefix(count))
            if !bypassing { process(near, into: &output) }
            if bypassing { output.append(near[...], at: start) }
            mic.removeFirst(count)
        }
        guard force, var run else { return }
        while !bypassing && run.emitted < run.fed + Self.processingDelay {
            process([], into: &output)
            run = self.run ?? run
        }
        self.run = nil
        skew = 0
    }

    /// Runs one 10 ms frame (`near` padded with silence) through AEC3 and emits the output that belongs to real
    /// microphone samples, moved back by `processingDelay` so it lines up with the raw microphone.
    /// If AEC3 fails, emits the raw samples still inside it and switches to bypass; `near` is then not consumed.
    private func process(_ near: [Float], into output: inout Output) {
        var run = self.run ?? Run(origin: mic.start)
        let position = run.origin + run.produced
        var frame = near + [Float](repeating: 0, count: Self.frame - near.count)
        let far = reference.frame(at: position + skew, count: Self.frame)
        let rendered = far.withUnsafeBufferPointer { webrtc_aec_analyze_render(aec, $0.baseAddress) }
        let processed = rendered == 0 ? frame.withUnsafeMutableBufferPointer { webrtc_aec_process_capture(aec, $0.baseAddress) } : rendered
        guard processed == 0 else {
            Self.log.error("echo cancellation failed (\(processed)); passing the microphone through")
            let owed = Int(run.fed + Self.processingDelay - run.emitted)
            output.append(run.recent.suffix(owed), at: run.origin + run.fed - Int64(owed))
            bypassing = true
            self.run = nil
            return
        }
        run.fed += Int64(near.count)
        run.recent = Array((run.recent + near).suffix(Int(Self.processingDelay)))
        let low = max(run.emitted, run.produced)
        let high = min(run.produced + Int64(Self.frame), run.fed + Self.processingDelay)
        if low < high {
            output.append(frame[Int(low - run.produced)..<Int(high - run.produced)], at: run.origin + low - Self.processingDelay)
            run.emitted = high
        }
        run.produced += Int64(Self.frame)
        // Keep reference past the microphone's real end: the tail's padding mustn't eat the next run's reference.
        reference.remove(before: min(position + Int64(Self.frame), run.origin + run.fed) + skew)
        self.run = run
    }

    static func index(of time: CMTime) throws -> Int64 {
        guard time.isNumeric else { throw Failure.invalidTime }
        return Int64((time.seconds * Double(sampleRate)).rounded())
    }

    private static func makeOutputFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        return format
    }
}

/// One stretch of continuous microphone audio, counted in AEC3 stream positions from `origin`.
/// Output position `p` belongs to input position `p - processingDelay`; the first outputs are AEC3's pre-roll.
private struct Run {
    let origin: Int64
    /// Real microphone samples fed so far (padding excluded).
    var fed: Int64 = 0
    /// Samples AEC3 has processed so far (padding included).
    var produced: Int64 = 0
    /// Next output position to emit; positions before `processingDelay` are pre-roll and skipped.
    var emitted: Int64 = EchoCanceller.processingDelay
    /// The last `processingDelay` raw samples fed: what's still inside AEC3 if it fails.
    var recent: [Float] = []
}

/// Samples on the 48 kHz timeline, `samples[0]` at index `start`.
private struct Timeline {
    var start: Int64 = 0
    var samples: [Float] = []

    var end: Int64 { start + Int64(samples.count) }

    /// `count` samples from `index`, silence where the timeline has none.
    func frame(at index: Int64, count: Int) -> [Float] {
        (0..<count).map { i in
            let offset = index + Int64(i) - start
            return offset >= 0 && offset < samples.count ? samples[Int(offset)] : 0
        }
    }

    mutating func removeFirst(_ count: Int) {
        samples.removeFirst(count)
        start += Int64(count)
    }

    mutating func remove(before index: Int64) {
        removeFirst(Int(max(0, min(index - start, Int64(samples.count)))))
    }
}

/// Cleaned audio from one call, one entry per run. Gaps between runs are not filled: the writer lays audio out by
/// sample count, and the raw microphone has no samples there either.
private struct Output {
    var runs: [(start: Int64, samples: [Float])] = []

    mutating func append(_ frame: ArraySlice<Float>, at index: Int64) {
        guard !frame.isEmpty else { return }
        if let last = runs.last, last.start + Int64(last.samples.count) == index {
            runs[runs.count - 1].samples += frame
        } else {
            runs.append((index, Array(frame)))
        }
    }

    func buffers(format: CMAudioFormatDescription) -> [CMSampleBuffer] {
        runs.compactMap { Self.buffer($0.samples, at: $0.start, format: format) }
    }

    private static func buffer(_ samples: [Float], at index: Int64, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            samples.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
            }) == noErr
        else { return nil }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: index, timescale: CMTimeScale(EchoCanceller.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }
}
