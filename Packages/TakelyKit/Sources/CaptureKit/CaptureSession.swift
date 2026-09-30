import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ProjectKit

/// Owns one recording: bundle, segments, sources. `recording ⇄ paused`, then `stop()`.
public actor CaptureSession {
    public enum State: Sendable, Equatable {
        case idle, recording, paused
    }

    public typealias SourceFactory = @Sendable (FrameRouter) throws -> [any FrameSource]

    public private(set) var state: State = .idle
    private let now: @Sendable () -> CMTime
    private let cursorLocation: @Sendable () -> CGPoint?
    private var bundle: ProjectBundle?
    private var project: Project?
    private var config: RecordingConfig?
    private var router: FrameRouter?
    private var sources: [any FrameSource] = []
    private var writer: SegmentWriter?
    private var nextSegmentIndex = 0
    /// Increments on every start; tags `events` so a late event can't affect a newer recording.
    private var recordingID = 0
    /// Stream failures and writer failures, for whoever runs the app's recording logic. Iterate it from
    /// exactly one task: each event goes to only one consumer. It finishes when the session is released.
    public nonisolated let events: AsyncStream<CaptureEvent>
    private let eventSink: AsyncStream<CaptureEvent>.Continuation
    /// The tail of the serialized operation queue; each new operation waits for this to finish.
    private var tail: Task<Void, Never>?
    private let log = Logger(subsystem: "app.takely", category: "capture")

    public init(
        now: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
        cursorLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }
    ) {
        self.now = now
        self.cursorLocation = cursorLocation
        (events, eventSink) = AsyncStream.makeStream(of: CaptureEvent.self)
    }

    deinit {
        eventSink.finish()
    }

    /// Runs `op` only after every previously enqueued operation has finished, so public calls
    /// (start/pause/resume/stop), even issued concurrently, never interleave across an `await`.
    private func serialized<T: Sendable>(_ op: @escaping @Sendable (isolated CaptureSession) async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await op(self)
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    /// Creates a bundle in `folder`, opens segment 0 and starts all sources.
    /// The handle's router is for forwarding clicks; its `id` tags this recording's `events`.
    @discardableResult
    public func start(config: RecordingConfig, in folder: URL, sources makeSources: @escaping SourceFactory) async throws
        -> RecordingHandle
    {
        try await serialized { session in try await session.startNow(config: config, in: folder, sources: makeSources) }
    }

    public func pause() async throws {
        try await serialized { session in try await session.pauseNow() }
    }

    public func resume() async throws {
        try await serialized { session in try await session.resumeNow() }
    }

    /// Stops sources, finalizes the manifest and returns the bundle.
    /// A failure closing the last segment is returned in `failure`; earlier segments are kept.
    public func stop() async throws -> StoppedRecording {
        try await serialized { session in try await session.stopNow() }
    }

    private func startNow(config: RecordingConfig, in folder: URL, sources makeSources: SourceFactory) async throws -> RecordingHandle {
        guard state == .idle else { throw CaptureError.invalidState }
        let bundle = try ProjectBundle.create(in: folder)
        let project = Project(
            capture: .init(target: config.target, pixelSize: config.outputSize, fps: config.fps, codec: config.codec),
            camera: .init(enabled: config.camera)
        )
        recordingID += 1
        let id = recordingID
        let sink = eventSink
        let router = FrameRouter(captureRect: config.captureRect, cursorLocation: cursorLocation) { kind, error in
            sink.yield(CaptureEvent(recordingID: id, kind: kind, error: error))
        }
        var writer: SegmentWriter?
        var sources: [any FrameSource] = []
        do {
            try bundle.write(project)
            let w = try openSegment(index: 0, in: bundle, config: config)
            writer = w
            router.attach(w, offset: 0)
            sources = try makeSources(router)
            for source in sources { try await source.start() }
        } catch {
            for source in sources { await source.stop() }
            router.attach(nil, offset: 0)
            _ = try? await writer?.finish(at: now())
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        self.bundle = bundle
        self.project = project
        self.config = config
        self.router = router
        self.sources = sources
        self.writer = writer
        self.nextSegmentIndex = 1
        state = .recording
        return RecordingHandle(id: id, bundle: bundle, router: router)
    }

    /// Writes the segment's sidecar, then opens its writer; writer failures become `.writerFailed` events.
    private func openSegment(index: Int, in bundle: ProjectBundle, config: RecordingConfig) throws -> SegmentWriter {
        let file = ProjectBundle.segmentFileName(index: index)
        try bundle.writeSidecar(tracks: config.tracks, for: file)
        let sink = eventSink
        let id = recordingID
        do {
            return try SegmentWriter(url: bundle.segmentURL(file), config: config.writerConfig) { error in
                sink.yield(CaptureEvent(recordingID: id, kind: .writerFailed, error: error))
            }
        } catch {
            // Leave nothing behind, so a later resume can reuse this index.
            try? FileManager.default.removeItem(at: bundle.sidecarURL(for: file))
            try? FileManager.default.removeItem(at: bundle.segmentURL(file))
            throw error
        }
    }

    private func pauseNow() async throws {
        guard state == .recording else { throw CaptureError.invalidState }
        defer { state = .paused }
        try await closeSegment()
    }

    private func resumeNow() async throws {
        guard state == .paused, let bundle, let project, let config, let router else { throw CaptureError.invalidState }
        let writer = try openSegment(index: nextSegmentIndex, in: bundle, config: config)
        router.attach(writer, offset: project.duration)
        router.prime(at: now())
        self.writer = writer
        nextSegmentIndex += 1
        state = .recording
    }

    private func stopNow() async throws -> StoppedRecording {
        guard state != .idle, let bundle else { throw CaptureError.invalidState }
        var failure: (any Error)?
        if state == .recording {
            do {
                try await closeSegment()
            } catch {
                log.error("closing last segment failed: \(error.localizedDescription)")
                failure = error
            }
        }
        for source in sources { await source.stop() }
        project?.status = .finished
        if let project {
            do { try bundle.write(project) } catch { log.error("writing final manifest failed: \(error.localizedDescription)") }
        }
        reset()
        return StoppedRecording(bundle: bundle, failure: failure)
    }

    private func closeSegment() async throws {
        guard let writer, let router, let bundle else { return }
        let offset = project?.duration ?? 0
        router.attach(nil, offset: offset)
        self.writer = nil
        let file = writer.url.lastPathComponent
        do {
            if let duration = try await writer.finish(at: now()) {
                project?.segments.append(.init(file: file, duration: duration, tracks: writer.writtenTracks))
            }
        } catch {
            // The segment isn't in the manifest, so its cursor samples would overlap the next segment's times.
            router.discardCursor(from: offset)
            throw error
        }
        let dropped = writer.droppedFrames
        if !dropped.isEmpty { log.info("\(file) dropped frames: \(String(describing: dropped))") }
        if let project { try bundle.write(project) }
        try bundle.write(router.cursor)
    }

    private func reset() {
        state = .idle
        bundle = nil
        project = nil
        config = nil
        router = nil
        sources = []
        writer = nil
        nextSegmentIndex = 0
    }
}
