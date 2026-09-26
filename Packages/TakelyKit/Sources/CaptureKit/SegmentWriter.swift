import AVFoundation
import ProjectKit
import Synchronization

public enum CaptureError: Error {
    case writerFailed(String)
    case noCamera
    case invalidState
}

/// Writes one segment `.mov` with one track per `TrackKind`. Thread-safe: sources append from their own queues.
///
/// `@unchecked Sendable`: `writer` and `inputs` are only touched inside `state`'s lock or after `finished` is set.
public final class SegmentWriter: @unchecked Sendable {
    public let url: URL
    public let tracks: [TrackKind]
    private let writer: AVAssetWriter
    private let inputs: [TrackKind: AVAssetWriterInput]
    private let frameDuration: CMTime

    private struct State {
        var start: CMTime?
        var lastScreen: UncheckedBuffer?
        var finished = false
        var dropped: [TrackKind: Int] = [:]
    }

    // ponytail: one lock across all tracks; split per input if signposts show contention.
    private let state = Mutex(State())

    public init(url: URL, config: WriterConfig) throws {
        self.url = url
        self.tracks = config.tracks
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        var inputs: [TrackKind: AVAssetWriterInput] = [:]
        for kind in config.tracks {
            let input = AVAssetWriterInput(mediaType: kind.isVideo ? .video : .audio, outputSettings: config.outputSettings(for: kind))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.writerFailed("cannot add \(kind) input") }
            writer.add(input)
            inputs[kind] = input
        }
        self.inputs = inputs
        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    /// Host-clock time of the first screen frame, once one has arrived.
    public var startTime: CMTime? { state.withLock { $0.start } }

    public var droppedFrames: [TrackKind: Int] { state.withLock { $0.dropped } }

    /// Appends `buffer`. The session starts at the first screen frame; earlier buffers are discarded.
    @discardableResult
    public func append(_ buffer: CMSampleBuffer, as kind: TrackKind) -> Bool {
        state.withLock { s in
            guard !s.finished, let input = inputs[kind] else { return false }
            let pts = buffer.presentationTimeStamp
            if s.start == nil {
                guard kind == .screen else { return false }
                writer.startSession(atSourceTime: pts)
                s.start = pts
            }
            guard let start = s.start, pts >= start else { return false }
            guard input.isReadyForMoreMediaData, input.append(buffer) else {
                s.dropped[kind, default: 0] += 1
                return false
            }
            if kind == .screen { s.lastScreen = UncheckedBuffer(buffer: buffer) }
            return true
        }
    }

    /// Finishes the file at host time `end`. Returns the segment duration in seconds,
    /// or `nil` (and deletes the file) if no screen frame ever arrived.
    public func finish(at end: CMTime) async throws -> Double? {
        let (start, lastScreen) = state.withLock { s in
            s.finished = true
            return (s.start, s.lastScreen)
        }
        guard let start else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // A static screen stops delivering frames; repeat the last one so video spans the whole segment.
        if let last = lastScreen?.buffer, let input = inputs[.screen],
            end - last.presentationTimeStamp > frameDuration,
            let repeated = last.retimed(to: end - frameDuration)
        {
            input.append(repeated)
        }
        inputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        return max(0, (end - start).seconds)
    }
}

/// Holds a sample buffer inside `Mutex` state; the buffer is immutable once delivered.
private struct UncheckedBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}
