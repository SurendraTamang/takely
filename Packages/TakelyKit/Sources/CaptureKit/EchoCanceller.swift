@preconcurrency import AVFoundation
import CoreMedia
import WebRTCAEC

/// Removes speaker playback from the microphone with WebRTC AEC3, using the system audio as the echo reference.
/// Both streams are converted to 48 kHz mono and placed on one sample timeline by their host-clock timestamps,
/// so clock drift or a gap in either only moves where samples land. Not thread-safe: `FrameRouter` calls it
/// under a lock (ScreenCaptureKit delivers both streams on one queue).
final class EchoCanceller {
    enum Failure: Error, Equatable {
        case formatChanged
        case conversion
        case processing(Int32)
    }

    static let sampleRate = 48_000
    /// AEC3 works on 10 ms frames.
    static let frame = sampleRate / 100
    /// How far the microphone may run ahead of its reference before the missing part counts as silence.
    static let maxWait = Int64(sampleRate * 150 / 1000)
    /// Timestamp jitter absorbed without treating it as a gap.
    static let tolerance = Int64(sampleRate / 1000)
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

    /// Nil if AEC3 can't be created.
    init?() {
        guard let aec = webrtc_aec_create(Int32(Self.sampleRate)), let format = Self.makeOutputFormat() else { return nil }
        self.aec = aec
        self.outputFormat = format
    }

    deinit { webrtc_aec_destroy(aec) }

    /// Adds system audio (the far end) to the reference timeline.
    func addReference(_ buffer: CMSampleBuffer) throws {
        let samples = try Downmixer.convert(buffer, with: &referenceConverter)
        let index = Self.index(of: buffer.presentationTimeStamp)
        if reference.samples.isEmpty || index < reference.start {
            reference = Timeline(start: index)
        } else if index > reference.end + Self.tolerance {
            reference.samples += [Float](repeating: 0, count: Int(index - reference.end))  // a gap in the playback is silence
        }
        let overlap = max(0, Int(min(reference.end, index + Int64(samples.count)) - index) - Int(Self.tolerance))
        reference.samples += samples.dropFirst(overlap)
        if reference.samples.count > Self.maxReference { reference.removeFirst(reference.samples.count - Self.maxReference) }
    }

    /// Adds microphone audio and returns whatever is ready: 48 kHz mono, echo removed, at the microphone's timestamps.
    func clean(_ buffer: CMSampleBuffer) throws -> CMSampleBuffer? {
        let samples = try Downmixer.convert(buffer, with: &micConverter)
        let index = Self.index(of: buffer.presentationTimeStamp)
        var output = Output()
        if !mic.samples.isEmpty, abs(index - mic.end) > Self.tolerance {
            try drain(force: true, into: &output)  // a gap in the microphone (e.g. after a pause) starts a new run
        }
        if mic.samples.isEmpty { mic = Timeline(start: index) }
        mic.samples += samples
        try drain(force: false, into: &output)
        return output.buffer(format: outputFormat)
    }

    /// Processes all pending microphone audio, treating any missing reference as silence.
    func flush() throws -> CMSampleBuffer? {
        var output = Output()
        try drain(force: true, into: &output)
        return output.buffer(format: outputFormat)
    }

    /// Processes pending microphone frames whose reference has arrived (or waited long enough).
    /// `force` processes everything and ends the run, pushing AEC3's delayed tail out.
    private func drain(force: Bool, into output: inout Output) throws {
        while mic.samples.count >= Self.frame || (force && !mic.samples.isEmpty) {
            let start = mic.start
            let referenceReady = reference.end >= start + Int64(Self.frame)
            guard force || referenceReady || mic.end - start >= Self.maxWait else { return }
            let count = min(Self.frame, mic.samples.count)
            try process(Array(mic.samples.prefix(count)), into: &output)
            mic.removeFirst(count)
        }
        guard force, var run else { return }
        while run.emitted < run.fed + Self.processingDelay {
            try process([], into: &output)
            run = self.run!
        }
        self.run = nil
    }

    /// Runs one 10 ms frame (`near` padded with silence) through AEC3 and emits the output that belongs to real
    /// microphone samples, moved back by `processingDelay` so it lines up with the raw microphone.
    private func process(_ near: [Float], into output: inout Output) throws {
        var run = self.run ?? Run(origin: mic.start)
        let position = run.origin + run.produced
        var frame = near + [Float](repeating: 0, count: Self.frame - near.count)
        let far = reference.frame(at: position, count: Self.frame)
        let rendered = far.withUnsafeBufferPointer { webrtc_aec_analyze_render(aec, $0.baseAddress) }
        guard rendered == 0 else { throw Failure.processing(rendered) }
        let processed = frame.withUnsafeMutableBufferPointer { webrtc_aec_process_capture(aec, $0.baseAddress) }
        guard processed == 0 else { throw Failure.processing(processed) }
        run.fed += Int64(near.count)
        let low = max(run.emitted, run.produced)
        let high = min(run.produced + Int64(Self.frame), run.fed + Self.processingDelay)
        if low < high {
            output.append(frame[Int(low - run.produced)..<Int(high - run.produced)], at: run.origin + low - Self.processingDelay)
            run.emitted = high
        }
        run.produced += Int64(Self.frame)
        reference.remove(before: position + Int64(Self.frame))
        self.run = run
    }

    static func index(of time: CMTime) -> Int64 { Int64((time.seconds * Double(sampleRate)).rounded()) }

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

/// Cleaned frames collected during one call, contiguous by construction except across a microphone gap.
private struct Output {
    var runs: [(start: Int64, samples: [Float])] = []

    mutating func append(_ frame: ArraySlice<Float>, at index: Int64) {
        if let last = runs.last, last.start + Int64(last.samples.count) == index {
            runs[runs.count - 1].samples += frame
        } else {
            runs.append((index, Array(frame)))
        }
    }

    /// One buffer for the newest run; earlier runs only exist across a microphone gap and are merged
    /// into one buffer with silence, which the writer lays out by timestamp anyway.
    func buffer(format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let first = runs.first, let last = runs.last else { return nil }
        let end = last.start + Int64(last.samples.count)
        var samples = [Float](repeating: 0, count: Int(end - first.start))
        for run in runs {
            samples.replaceSubrange(Int(run.start - first.start)..<Int(run.start - first.start) + run.samples.count, with: run.samples)
        }
        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            samples.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
            })
                == noErr
        else { return nil }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: first.start, timescale: CMTimeScale(EchoCanceller.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }
}

/// Converts one stream's buffers to 48 kHz mono Float32. The stream's format must not change.
private final class Downmixer {
    private let source: CMAudioFormatDescription
    private let input: AVAudioFormat
    private let converter: AVAudioConverter
    private static let output = AVAudioFormat(standardFormatWithSampleRate: Double(EchoCanceller.sampleRate), channels: 1)!

    private init?(_ source: CMAudioFormatDescription) {
        let input = AVAudioFormat(cmAudioFormatDescription: source)
        guard let converter = AVAudioConverter(from: input, to: Self.output) else { return nil }
        self.source = source
        self.input = input
        self.converter = converter
    }

    static func convert(_ buffer: CMSampleBuffer, with downmixer: inout Downmixer?) throws -> [Float] {
        guard let format = buffer.formatDescription else { throw EchoCanceller.Failure.conversion }
        if downmixer == nil { downmixer = Downmixer(format) }
        guard let downmixer else { throw EchoCanceller.Failure.conversion }
        guard CMFormatDescriptionEqual(format, otherFormatDescription: downmixer.source) else { throw EchoCanceller.Failure.formatChanged }
        return try downmixer.convert(buffer)
    }

    private func convert(_ buffer: CMSampleBuffer) throws -> [Float] {
        let frames = AVAudioFrameCount(buffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames) else { throw EchoCanceller.Failure.conversion }
        pcm.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
                == noErr
        else { throw EchoCanceller.Failure.conversion }
        let capacity = AVAudioFrameCount((Double(frames) * Self.output.sampleRate / input.sampleRate).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.output, frameCapacity: capacity) else {
            throw EchoCanceller.Failure.conversion
        }
        nonisolated(unsafe) var consumed = false  // the input block runs synchronously inside `convert`
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        guard status != .error, let channel = converted.floatChannelData else { throw EchoCanceller.Failure.conversion }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
    }
}
