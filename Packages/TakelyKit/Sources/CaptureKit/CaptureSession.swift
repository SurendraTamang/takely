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
    private var bundle: ProjectBundle?
    private var project: Project?
    private var config: RecordingConfig?
    private var router: FrameRouter?
    private var sources: [any FrameSource] = []
    private var writer: SegmentWriter?

    public init(now: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) {
        self.now = now
    }

    /// Creates a bundle in `folder`, opens segment 0 and starts all sources.
    /// Returns the router so the caller can forward clicks to it.
    @discardableResult
    public func start(config: RecordingConfig, in folder: URL, sources makeSources: SourceFactory) async throws -> FrameRouter {
        guard state == .idle else { throw CaptureError.invalidState }
        let bundle = try ProjectBundle.create(in: folder)
        let project = Project(
            capture: .init(target: config.target, pixelSize: config.outputSize, fps: config.fps, codec: config.codec),
            camera: .init(enabled: config.camera)
        )
        try bundle.write(project)
        let router = FrameRouter(captureRect: config.captureRect)
        let writer = try SegmentWriter(url: bundle.segmentURL(ProjectBundle.segmentFileName(index: 0)), config: config.writerConfig)
        router.attach(writer, offset: 0)
        let sources = try makeSources(router)
        do {
            for source in sources { try await source.start() }
        } catch {
            for source in sources { await source.stop() }
            _ = try? await writer.finish(at: now())
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        self.bundle = bundle
        self.project = project
        self.config = config
        self.router = router
        self.sources = sources
        self.writer = writer
        state = .recording
        return router
    }

    public func pause() async throws {
        guard state == .recording else { throw CaptureError.invalidState }
        try await closeSegment()
        state = .paused
    }

    public func resume() throws {
        guard state == .paused, let bundle, let project, let config, let router else { throw CaptureError.invalidState }
        let index = project.segments.count
        let writer = try SegmentWriter(url: bundle.segmentURL(ProjectBundle.segmentFileName(index: index)), config: config.writerConfig)
        router.attach(writer, offset: project.duration)
        self.writer = writer
        state = .recording
    }

    /// Stops sources, finalizes the manifest and returns the bundle.
    public func stop() async throws -> ProjectBundle {
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
    }
}
