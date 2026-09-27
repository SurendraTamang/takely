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
/// `@unchecked Sendable`: `writer` and `inputs` are only touched inside `state`'s lock, or by the single
/// `finish` call that wins the lock after appends are shut off.
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
        var failure: (any Error)?
        var dropped: [TrackKind: Int] = [:]
        /// Last appended PTS per video track; AVAssetWriter fails the whole file on a non-increasing one.
        var lastVideoPTS: [TrackKind: CMTime] = [:]
        var written: Set<TrackKind> = []
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

    /// Set once the underlying writer fails; the segment then accepts nothing more.
    public var failure: (any Error)? { state.withLock { $0.failure } }

    /// Tracks that received at least one sample, in track-ID order. AVAssetWriter omits empty inputs from the file.
    public var writtenTracks: [TrackKind] { state.withLock { s in tracks.filter { s.written.contains($0) } } }

    /// Appends `buffer`. The session starts at the first screen frame; earlier buffers are discarded.
    @discardableResult
    public func append(_ buffer: CMSampleBuffer, as kind: TrackKind) -> Bool {
        state.withLock { s in
            guard !s.finished, s.failure == nil, let input = inputs[kind] else { return false }
            if s.start == nil {
                guard kind == .screen, writer.status == .writing else { return false }
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                s.start = buffer.presentationTimeStamp
            }
            guard let start = s.start, Self.overlapsSession(buffer, kind: kind, start: start) else { return false }
            if kind.isVideo, let last = s.lastVideoPTS[kind], buffer.presentationTimeStamp <= last { return false }
            guard input.isReadyForMoreMediaData, input.append(buffer) else {
                if writer.status == .failed {
                    s.failure = writer.error ?? CaptureError.writerFailed("writer failed")
                } else {
                    s.dropped[kind, default: 0] += 1
                }
                return false
            }
            if kind.isVideo { s.lastVideoPTS[kind] = buffer.presentationTimeStamp }
            s.written.insert(kind)
            if kind == .screen { s.lastScreen = UncheckedBuffer(buffer: buffer) }
            return true
        }
    }

    /// Video must start at or after the session start; audio may straddle it (the writer trims the overlap).
    private static func overlapsSession(_ buffer: CMSampleBuffer, kind: TrackKind, start: CMTime) -> Bool {
        let pts = buffer.presentationTimeStamp
        return pts >= start || (!kind.isVideo && pts + buffer.duration > start)
    }

    /// Finishes the file at host time `end`. Returns the segment duration in seconds, or `nil`
    /// (and deletes the file) if no screen frame ever arrived. Later calls return `nil`.
    public func finish(at end: CMTime) async throws -> Double? {
        let (alreadyFinished, start, lastScreen) = state.withLock { s in
            defer { s.finished = true }
            return (s.finished, s.start, s.lastScreen)
        }
        if alreadyFinished { return nil }
        guard let start else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // A static screen stops delivering frames and `endSession` does not stretch the last one,
        // so repeat it just before `end` (see staticScreenSpansWholeSegment).
        if let last = lastScreen?.buffer, let input = inputs[.screen],
            end - last.presentationTimeStamp > frameDuration,
            let repeated = last.retimed(to: end - frameDuration)
        {
            // Appends are shut off, so the encoder only drains now; wait briefly rather than append while
            // not ready, which raises an Objective-C exception.
            var waits = 0
            while !input.isReadyForMoreMediaData && waits < 50 {
                try? await Task.sleep(for: .milliseconds(10))
                waits += 1
            }
            if input.isReadyForMoreMediaData { input.append(repeated) }
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
struct UncheckedBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}
