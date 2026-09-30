@preconcurrency import AVFoundation
import CoreMedia
import OSLog
import WebRTCAEC

/// Removes speaker playback from the microphone with WebRTC AEC3, using the system audio as the echo reference.
///
/// The writer lays audio out by sample count (only a track's first timestamp counts), so the cleaned microphone
/// must contain exactly the raw microphone's samples: one output sample per input sample, in order. The reference
/// is placed on the microphone's timeline by host-clock timestamps; the microphone itself follows its sample count
/// and only a jump over `micGap` (e.g. a pause) starts a new run. Not thread-safe: `FrameRouter` calls it under a
/// lock (ScreenCaptureKit delivers both streams on one queue).
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

    /// Adds system audio (the far end) to the reference timeline.
    func addReference(_ buffer: CMSampleBuffer) throws {
        let index = try Self.index(of: buffer.presentationTimeStamp)
        if let format = buffer.formatDescription, referenceConverter?.handles(format) == false { referenceConverter = nil }
        let samples = try Downmixer.convert(buffer, with: &referenceConverter)
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
    func clean(_ buffer: CMSampleBuffer) throws -> [CMSampleBuffer] {
        let index = try Self.index(of: buffer.presentationTimeStamp)
        var output = Output()
        if let format = buffer.formatDescription, micConverter?.handles(format) == false {
            try drain(force: true, into: &output)  // e.g. a headset connected: finish the run, then convert the new format
            micConverter = nil
        }
        let samples = try Downmixer.convert(buffer, with: &micConverter)
        if run != nil || !mic.samples.isEmpty, index > mic.end + Self.micGap {
            try drain(force: true, into: &output)  // a gap in the microphone (e.g. after a pause) starts a new run
        }
        if run == nil && mic.samples.isEmpty { mic = Timeline(start: index) }
        mic.samples += samples
        try drain(force: false, into: &output)
        return output.buffers(format: outputFormat)
    }

    /// Processes all pending microphone audio (missing reference counts as silence) and ends the run.
    func flush() throws -> [CMSampleBuffer] {
        var output = Output()
        try drain(force: true, into: &output)
        return output.buffers(format: outputFormat)
    }

    /// Processes pending microphone frames whose reference has arrived (or waited long enough).
    /// `force` processes everything and ends the run, pushing AEC3's delayed tail out.
    private func drain(force: Bool, into output: inout Output) throws {
        while mic.samples.count >= Self.frame || (force && !mic.samples.isEmpty) {
            let start = mic.start
            let referenceReady = reference.end >= start + Int64(Self.frame)
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
    }

    /// Runs one 10 ms frame (`near` padded with silence) through AEC3 and emits the output that belongs to real
    /// microphone samples, moved back by `processingDelay` so it lines up with the raw microphone.
    /// If AEC3 fails, emits the raw samples still inside it and switches to bypass; `near` is then not consumed.
    private func process(_ near: [Float], into output: inout Output) {
        var run = self.run ?? Run(origin: mic.start)
        let position = run.origin + run.produced
        var frame = near + [Float](repeating: 0, count: Self.frame - near.count)
        let far = reference.frame(at: position, count: Self.frame)
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
        reference.remove(before: position + Int64(Self.frame))
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

/// Converts one stream's buffers (of one format) to 48 kHz mono Float32.
/// 48 kHz input is downmixed directly, so every buffer's samples stay with its timestamp. Other rates go through
/// `AVAudioConverter`, which keeps up to a chunk of samples until more input arrives (`exact` is false).
private final class Downmixer {
    private let source: CMAudioFormatDescription
    private let input: AVAudioFormat
    private let converter: AVAudioConverter?
    let exact: Bool
    private static let output = AVAudioFormat(standardFormatWithSampleRate: Double(EchoCanceller.sampleRate), channels: 1)!

    private init?(_ source: CMAudioFormatDescription) {
        let input = AVAudioFormat(cmAudioFormatDescription: source)
        let direct =
            input.sampleRate == Self.output.sampleRate
            && [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32].contains(input.commonFormat)
        let converter = direct ? nil : AVAudioConverter(from: input, to: Self.output)
        guard direct || converter != nil else { return nil }
        self.source = source
        self.input = input
        self.converter = converter
        self.exact = direct
    }

    func handles(_ format: CMFormatDescription) -> Bool { CMFormatDescriptionEqual(format, otherFormatDescription: source) }

    /// Converts with `downmixer`, creating one for the buffer's format if there is none.
    static func convert(_ buffer: CMSampleBuffer, with downmixer: inout Downmixer?) throws -> [Float] {
        guard let format = buffer.formatDescription else { throw EchoCanceller.Failure.conversion }
        if downmixer == nil { downmixer = Downmixer(format) }
        guard let downmixer, downmixer.handles(format) else { throw EchoCanceller.Failure.conversion }
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
        guard let converter else { return try Self.downmix(pcm) }
        let capacity = AVAudioFrameCount((Double(frames) * Self.output.sampleRate / input.sampleRate).rounded(.up)) + 4096
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

    /// Averages the channels of 48 kHz linear PCM (interleaved or not).
    private static func downmix(_ pcm: AVAudioPCMBuffer) throws -> [Float] {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        let interleaved = pcm.format.isInterleaved
        func mix<T>(_ data: UnsafePointer<UnsafeMutablePointer<T>>, scale: Float, _ value: (T) -> Float) -> [Float] {
            (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += value(interleaved ? data[0][frame * channels + channel] : data[channel][frame]) }
                return sum * scale / Float(channels)
            }
        }
        if let data = pcm.floatChannelData { return mix(data, scale: 1) { $0 } }
        if let data = pcm.int16ChannelData { return mix(data, scale: 1 / 32_768) { Float($0) } }
        if let data = pcm.int32ChannelData { return mix(data, scale: 1 / 2_147_483_648) { Float($0) } }
        throw EchoCanceller.Failure.conversion
    }
}
