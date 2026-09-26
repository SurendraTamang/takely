import CoreGraphics
import CoreMedia
import Foundation
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
    /// The tail of the serialized operation queue; each new operation waits for this to finish.
    private var tail: Task<Void, Never>?

    public init(
        now: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
        cursorLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }
    ) {
        self.now = now
        self.cursorLocation = cursorLocation
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
    /// Returns the router so the caller can forward clicks to it.
    @discardableResult
    public func start(config: RecordingConfig, in folder: URL, sources makeSources: @escaping SourceFactory) async throws -> FrameRouter {
        try await serialized { session in try await session.startNow(config: config, in: folder, sources: makeSources) }
    }

    public func pause() async throws {
        try await serialized { session in try await session.pauseNow() }
    }

    public func resume() async throws {
        try await serialized { session in try await session.resumeNow() }
    }

    /// Stops sources, finalizes the manifest and returns the bundle.
    public func stop() async throws -> ProjectBundle {
        try await serialized { session in try await session.stopNow() }
    }

    private func startNow(config: RecordingConfig, in folder: URL, sources makeSources: SourceFactory) async throws -> FrameRouter {
        guard state == .idle else { throw CaptureError.invalidState }
        let bundle = try ProjectBundle.create(in: folder)
        let project = Project(
            capture: .init(target: config.target, pixelSize: config.outputSize, fps: config.fps, codec: config.codec),
            camera: .init(enabled: config.camera)
        )
        let router = FrameRouter(captureRect: config.captureRect, cursorLocation: cursorLocation)
        var writer: SegmentWriter?
        var sources: [any FrameSource] = []
        do {
            try bundle.write(project)
            let w = try SegmentWriter(url: bundle.segmentURL(ProjectBundle.segmentFileName(index: 0)), config: config.writerConfig)
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
        return router
    }

    private func pauseNow() async throws {
        guard state == .recording else { throw CaptureError.invalidState }
        try await closeSegment()
        state = .paused
    }

    private func resumeNow() async throws {
        guard state == .paused, let bundle, let project, let config, let router else { throw CaptureError.invalidState }
        let index = nextSegmentIndex
        let writer = try SegmentWriter(url: bundle.segmentURL(ProjectBundle.segmentFileName(index: index)), config: config.writerConfig)
        router.attach(writer, offset: project.duration)
        self.writer = writer
        nextSegmentIndex += 1
        state = .recording
    }

    private func stopNow() async throws -> ProjectBundle {
        guard state != .idle, let bundle else { throw CaptureError.invalidState }
        if state == .recording { try await closeSegment() }
        for source in sources { await source.stop() }
        project?.status = .finished
        if let project { try bundle.write(project) }
        reset()
        return bundle
    }

    private func closeSegment() async throws {
        guard let writer, let router, let bundle else { return }
        router.attach(nil, offset: project?.duration ?? 0)
        self.writer = nil
        if let duration = try await writer.finish(at: now()) {
            project?.segments.append(.init(file: writer.url.lastPathComponent, duration: duration, tracks: writer.tracks))
        }
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
