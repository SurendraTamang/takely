import AVFoundation
import Foundation
import Testing

@testable import CaptureKit

/// Runs the canceller over a real Takely segment (system audio = first audio track, microphone = second).
/// Opt-in: `TAKELY_AEC_SEGMENT=/path/segment-000.mov swift test --filter EchoRecordingTests`.
@Suite struct EchoRecordingTests {
    static let segment = ProcessInfo.processInfo.environment["TAKELY_AEC_SEGMENT"]

    /// The track's buffers as 48 kHz stereo Float32 LPCM, with their original timestamps.
    static func buffers(of track: AVAssetTrack, in asset: AVAsset) throws -> [CMSampleBuffer] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        reader.startReading()
        var buffers: [CMSampleBuffer] = []
        while let buffer = output.copyNextSampleBuffer() { buffers.append(buffer) }
        return buffers
    }

    static func mono(_ buffers: [CMSampleBuffer]) throws -> (start: Int64, samples: [Float]) {
        var samples: [Float] = []
        for buffer in buffers {
            let block = try #require(buffer.dataBuffer)
            var stereo = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            stereo.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            for i in stride(from: 0, to: stereo.count - 1, by: 2) {
                let left: Float = stereo[i]
                let right: Float = stereo[i + 1]
                samples.append((left + right) / 2)
            }
        }
        return (try EchoCanceller.index(of: buffers.first?.presentationTimeStamp ?? .zero), samples)
    }

    @Test(.enabled(if: segment != nil)) func removesEchoFromARealRecording() async throws {
        let asset = AVURLAsset(url: URL(filePath: try #require(Self.segment)))
        let audio = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        try #require(audio.count >= 2)
        let system = try Self.buffers(of: audio[0], in: asset)
        let mic = try Self.buffers(of: audio[1], in: asset)

        // Feed both streams in timestamp order, as ScreenCaptureKit's single audio queue would.
        let canceller = try #require(EchoCanceller())
        var cleaned: [CMSampleBuffer] = []
        var s = 0
        for buffer in mic {
            while s < system.count, system[s].presentationTimeStamp <= buffer.presentationTimeStamp {
                try canceller.addReference(system[s])
                s += 1
            }
            cleaned += try canceller.clean(buffer)
        }
        cleaned += try canceller.flush()

        let far = try Self.mono(system)
        let near = try Self.mono(mic)
        var out: [Float] = []
        let outStart = try EchoCanceller.index(of: try #require(cleaned.first).presentationTimeStamp)
        for buffer in cleaned { out += try EchoCancellerTests.floats(buffer) }

        // Echo-only windows: 0.5 s where the system audio plays (> −40 dBFS), after 2 s of convergence.
        let window = 24_000
        var micPower = 0.0
        var outPower = 0.0
        var windows = 0
        for w in stride(from: 48_000 * 2, to: near.samples.count - window, by: window) {
            let t = near.start + Int64(w)
            let f = Int(t - far.start)
            let o = Int(t - outStart)
            guard f >= 0, f + window <= far.samples.count, o >= 0, o + window <= out.count else { continue }
            guard 10 * log10(EchoCancellerTests.power(far.samples[f..<f + window]) + 1e-20) > -40 else { continue }
            micPower += EchoCancellerTests.power(near.samples[w..<w + window])
            outPower += EchoCancellerTests.power(out[o..<o + window])
            windows += 1
        }
        try #require(windows > 0, "no windows with system audio playing")
        let erle = 10 * log10(micPower / max(outPower, 1e-20))
        print("real recording: \(windows) windows, ERLE \(erle) dB")
        #expect(erle >= 25, "ERLE \(erle) dB over \(windows) windows")
    }
}
