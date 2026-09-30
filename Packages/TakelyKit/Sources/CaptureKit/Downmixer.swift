@preconcurrency import AVFoundation
import CoreMedia

/// Converts one stream's buffers (of one format) to 48 kHz mono Float32.
/// 48 kHz input is downmixed directly, so every buffer's samples stay with its timestamp. Other rates go through
/// `AVAudioConverter`, which keeps up to a chunk of samples until more input arrives (`exact` is false).
final class Downmixer {
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
