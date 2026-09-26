import CoreGraphics
import CoreMedia
import Foundation
import ProjectKit
import Synchronization
import TestSupport
import Testing

@testable import CaptureKit

/// Test double: the test pushes frames through the router it was given.
final class FakeSource: FrameSource {
    let router: FrameRouter
    let started = Mutex(false)

    init(router: FrameRouter) { self.router = router }

    func start() async throws { started.withLock { $0 = true } }
    func stop() async { started.withLock { $0 = false } }

    /// Pushes `seconds` of 30 fps screen frames starting at host time `from`.
    func emitScreen(from: Double, seconds: Double) async throws {
        for i in 0..<Int(seconds * 30) {
            let pts = Synthetic.seconds(from + Double(i) / 30)
            router.receive(Synthetic.video(width: 64, height: 40, pts: pts, rgb: (255, 0, 0)), kind: .screen)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

final class FakeClock: Sendable {
    let value = Mutex(0.0)
    func set(_ seconds: Double) { value.withLock { $0 = seconds } }
    var now: @Sendable () -> CMTime { { Synthetic.seconds(self.value.withLock { $0 }) } }
}

/// A source whose `start()` takes a while, to widen the window for concurrent-start races.
final class SlowStartSource: FrameSource {
    let router: FrameRouter
    let started = Mutex(false)

    init(router: FrameRouter) { self.router = router }

    func start() async throws {
        try await Task.sleep(for: .milliseconds(50))
        started.withLock { $0 = true }
    }
    func stop() async { started.withLock { $0 = false } }
}

func attempt<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

@Suite struct CaptureSessionTests {
    let config = RecordingConfig(
        target: .display, captureRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        sourcePixelSize: PixelSize(width: 64, height: 40), resolution: .native,
        codec: .h264, systemAudio: false, microphone: false
    )

    func makeSession() -> (CaptureSession, FakeClock) {
        let clock = FakeClock()
        return (CaptureSession(now: clock.now, cursorLocation: { CGPoint(x: 50, y: 50) }), clock)
    }

    @Test func recordStopProducesFinishedManifest() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        #expect(source.started.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        clock.set(101)
        let bundle = try await session.stop()

        let project = try bundle.readProject()
        #expect(project.status == .finished)
        #expect(project.segments.map(\.file) == ["segment-000.mov"])
        #expect(abs(project.duration - 1) < 0.001)
        #expect(!source.started.withLock { $0 })
        #expect(await session.state == .idle)
    }

    @Test func pauseResumeWritesTwoSegmentsOnOneTimeline() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        clock.set(101)
        try await session.pause()
        #expect(await session.state == .paused)

        try await source.emitScreen(from: 150, seconds: 0.5)  // dropped while paused
        clock.set(200)
        try await session.resume()
        try await source.emitScreen(from: 200.01, seconds: 2)
        clock.set(202)
        let bundle = try await session.stop()

        let project = try bundle.readProject()
        #expect(project.segments.map(\.file) == ["segment-000.mov", "segment-001.mov"])
        #expect(abs(project.duration - 3) < 0.001)
        // Cursor times continue across the pause: segment 2 starts at t = 1.0, not at 0 or 100.
        let times = try bundle.readCursor().samples.map(\.t)
        #expect(times.contains { abs($0 - 1.0) < 1e-6 })
        #expect(times.allSatisfy { $0 < 3 })
    }

    @Test func resumeOnStaticScreenStartsImmediately() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        clock.set(101)
        try await session.pause()

        clock.set(150)
        try await session.resume()
        // No frames emitted: the screen is static.
        clock.set(152)
        let bundle = try await session.stop()

        let project = try bundle.readProject()
        #expect(project.segments.map(\.file) == ["segment-000.mov", "segment-001.mov"])
        #expect(abs(project.duration - 3.0) < 0.01)
    }

    @Test func cannotStartTwice() async throws {
        let (session, _) = makeSession()
        let folder = Synthetic.temporaryFolder()
        try await session.start(config: config, in: folder) { [FakeSource(router: $0)] }
        await #expect(throws: CaptureError.self) {
            try await session.start(config: config, in: folder) { [FakeSource(router: $0)] }
        }
    }

    @Test func failedSourceStartRemovesBundle() async throws {
        struct Boom: Error {}
        final class FailingSource: FrameSource {
            func start() async throws { throw Boom() }
            func stop() async {}
        }
        let (session, _) = makeSession()
        let folder = Synthetic.temporaryFolder()
        await #expect(throws: Boom.self) {
            try await session.start(config: config, in: folder) { _ in [FailingSource()] }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(await session.state == .idle)
    }

    @Test func stopDuringPauseKeepsSegment() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        clock.set(101)

        let p = Task { try await session.pause() }
        let s = Task { try await session.stop() }
        _ = await p.result
        let bundle = try await s.value

        let project = try bundle.readProject()
        #expect(project.status == .finished)
        #expect(project.segments.map(\.file) == ["segment-000.mov"])
        #expect(await session.state == .idle)

        // The session can start again.
        try await session.start(config: config, in: Synthetic.temporaryFolder()) { [FakeSource(router: $0)] }
    }

    @Test func doubleStopKeepsSegment() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        clock.set(101)

        async let first = attempt { try await session.stop() }
        let second = await attempt { try await session.stop() }
        let outcomes = [await first, second]

        var successes: [ProjectBundle] = []
        var captureErrors = 0
        for outcome in outcomes {
            switch outcome {
            case .success(let bundle): successes.append(bundle)
            case .failure(let error): if error is CaptureError { captureErrors += 1 }
            }
        }
        #expect(successes.count == 1)
        #expect(captureErrors == 1)

        let bundle = try #require(successes.first)
        let project = try bundle.readProject()
        #expect(project.status == .finished)
        #expect(project.segments.map(\.file) == ["segment-000.mov"])
    }

    @Test func concurrentStartsLeakNothing() async throws {
        let session = CaptureSession(cursorLocation: { CGPoint(x: 50, y: 50) })
        // Separate boxes per attempt: a single `Mutex` can't be captured by two independent closures.
        let sourceA = Mutex<SlowStartSource?>(nil)
        let sourceB = Mutex<SlowStartSource?>(nil)
        let folderA = Synthetic.temporaryFolder()
        let folderB = Synthetic.temporaryFolder()

        async let a = attempt {
            try await session.start(config: config, in: folderA) { router in
                let source = SlowStartSource(router: router)
                sourceA.withLock { $0 = source }
                return [source]
            }
        }
        async let b = attempt {
            try await session.start(config: config, in: folderB) { router in
                let source = SlowStartSource(router: router)
                sourceB.withLock { $0 = source }
                return [source]
            }
        }
        let outcomes = [await a, await b]

        var successes = 0
        var captureErrors = 0
        for outcome in outcomes {
            switch outcome {
            case .success: successes += 1
            case .failure(let error): if error is CaptureError { captureErrors += 1 }
            }
        }
        #expect(successes == 1)
        #expect(captureErrors == 1)

        _ = try? await session.stop()
        #expect(!(sourceA.withLock { $0?.started.withLock { $0 } } ?? false))
        #expect(!(sourceB.withLock { $0?.started.withLock { $0 } } ?? false))
    }

    @Test func throwingFactoryRemovesBundle() async throws {
        struct Boom: Error {}
        let session = CaptureSession(cursorLocation: { CGPoint(x: 50, y: 50) })
        let folder = Synthetic.temporaryFolder()
        await #expect(throws: Boom.self) {
            try await session.start(config: config, in: folder) { _ in throw Boom() }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(await session.state == .idle)
    }
}

@Suite struct FrameRouterTests {
    @Test func cursorTimesAreOnEditedTimeline() throws {
        let router = FrameRouter(captureRect: CGRect(x: 100, y: 0, width: 200, height: 100)) { CGPoint(x: 200, y: 25) }
        let url = Synthetic.temporaryFolder().appending(path: "s.mov")
        let writer = try SegmentWriter(
            url: url,
            config: WriterConfig(
                tracks: [.screen], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
        router.attach(writer, offset: 10)
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50.5), rgb: (0, 0, 0)), kind: .screen)
        router.recordClick(at: Synthetic.seconds(50.25))

        let cursor = router.cursor
        #expect(cursor.samples.map(\.t) == [10, 10.5])
        #expect(cursor.samples.first.map { NormalizedPoint(x: $0.x, y: $0.y) } == NormalizedPoint(x: 0.5, y: 0.25))
        #expect(cursor.clicks.map(\.t) == [10.25])
    }

    @Test func detachedRouterDropsFrames() {
        let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100)) { CGPoint(x: 50, y: 50) }
        router.receive(Synthetic.video(width: 8, height: 8, pts: .zero, rgb: (0, 0, 0)), kind: .screen)
        #expect(router.cursor.samples.isEmpty)
    }

    @Test func primeStartsSegmentFromLastFrame() throws {
        let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100)) { CGPoint(x: 50, y: 50) }
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        let url = Synthetic.temporaryFolder().appending(path: "s.mov")
        let writer = try SegmentWriter(
            url: url,
            config: WriterConfig(
                tracks: [.screen], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
        router.attach(writer, offset: 0)
        router.prime(at: Synthetic.seconds(60))
        #expect(writer.startTime == Synthetic.seconds(60))
    }
}
