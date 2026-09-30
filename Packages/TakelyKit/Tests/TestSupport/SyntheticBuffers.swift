import AVFoundation
import CoreMedia

/// Solid-color frames and silent audio for writer/export tests.
public enum Synthetic {
    public static func video(width: Int, height: Int, pts: CMTime, fps: Int32 = 30, rgb: (UInt8, UInt8, UInt8)) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * bytesPerRow + x * 4
                p[0] = rgb.2
                p[1] = rgb.1
                p[2] = rgb.0
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    /// 1024 frames of 48 kHz stereo Float32 silence.
    public static func audio(pts: CMTime, frames: Int = 1024) -> CMSampleBuffer {
        audio(pts: pts, samples: [Float](repeating: 0, count: frames * 2), channels: 2)
    }

    /// Float32 LPCM with the given interleaved samples (`samples.count` must be a multiple of `channels`).
    /// `interleaved: false` stores them channel after channel, as ScreenCaptureKit delivers audio.
    public static func audio(
        pts: CMTime, samples: [Float], channels: Int, sampleRate: Double = 48_000, interleaved: Bool = true
    ) -> CMSampleBuffer {
        let frames = samples.count / channels
        let samples = interleaved ? samples : (0..<channels).flatMap { c in (0..<frames).map { samples[$0 * channels + c] } }
        let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: samples.count / channels,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    public static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 48_000)
    }

    public static func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "takely-tests", directoryHint: .isDirectory).appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension Array {
    public func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
