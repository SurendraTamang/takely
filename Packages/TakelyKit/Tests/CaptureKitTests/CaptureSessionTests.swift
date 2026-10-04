import AVFoundation
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
        let stopped = try await session.stop()
        #expect(stopped.failure == nil)

        let project = try stopped.bundle.readProject()
        #expect(project.status == .finished)
        #expect(project.segments.map(\.file) == ["segment-000.mov"])
        #expect(project.segments.first?.tracks == [.screen])
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
        try await source.emitScreen(from: 200, seconds: 2)
        clock.set(202)
        let bundle = try await session.stop().bundle

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
        let bundle = try await session.stop().bundle

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

    @Test func sourcesWarmUpDuringTheArmedStepAndTheSegmentStartsAfterIt() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        let folder = Synthetic.temporaryFolder()
        let handle = try await session.start(
            config: config, in: folder,
            sources: { router in
                let source = FakeSource(router: router)
                fake.withLock { $0 = source }
                return [source]
            },
            armed: {
                // The countdown: sources already run, but nothing is written yet.
                let source = try #require(fake.withLock { $0 })
                #expect(source.started.withLock { $0 })
                let files = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
                #expect(!files.contains { $0.hasSuffix(".mov") }, "no segment before the countdown ends: \(files)")
                try await source.emitScreen(from: 100, seconds: 1)
                clock.set(103)
            })
        #expect(FileManager.default.fileExists(atPath: handle.bundle.segmentURL("segment-000.mov").path))
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 103, seconds: 1)
        clock.set(104)
        let project = try await session.stop().bundle.readProject()
        // The segment starts at the end of the countdown (primed with the last frame), not at the first warm-up frame.
        let duration = try #require(project.segments.first?.duration)
        #expect(abs(duration - 1) < 0.1, "segment duration \(duration)")
    }

    @Test func cancellingTheArmedStepLeavesNothingBehind() async throws {
        let (session, _) = makeSession()
        let folder = Synthetic.temporaryFolder()
        let fake = Mutex<FakeSource?>(nil)
        await #expect(throws: CancellationError.self) {
            try await session.start(
                config: config, in: folder,
                sources: { router in
                    let source = FakeSource(router: router)
                    fake.withLock { $0 = source }
                    return [source]
                },
                armed: { throw CancellationError() })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(fake.withLock { $0?.started.withLock { $0 } } == false)
        #expect(await session.state == .idle)
    }

    @Test func aStreamThatStopsDuringTheCountdownFailsTheStart() async throws {
        struct DisplayUnplugged: Error {}
        let (session, _) = makeSession()
        let folder = Synthetic.temporaryFolder()
        let fake = Mutex<FakeSource?>(nil)
        await #expect(throws: DisplayUnplugged.self) {
            try await session.start(
                config: config, in: folder,
                sources: { router in
                    let source = FakeSource(router: router)
                    fake.withLock { $0 = source }
                    return [source]
                },
                armed: { fake.withLock { $0 }?.router.reportStreamStopped(DisplayUnplugged(), userInitiated: false) })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)  // no dead recording left
        #expect(await session.state == .idle)
    }

    /// Speaks into the router's microphone input: `pattern` of (seconds, speaking?) from host time `from`.
    func speak(_ router: FrameRouter, from: Double, _ pattern: [(Double, Bool)]) {
        let samples = SilenceDetectorTests.audio(pattern)
        for chunk in stride(from: 0, to: samples.count, by: 1024) {
            let part = Array(samples[chunk..<min(chunk + 1024, samples.count)])
            router.receive(Synthetic.audio(pts: Synthetic.seconds(from + Double(chunk) / 48_000), samples: part, channels: 1), kind: .mic)
        }
    }

    @Test func retakeCutsBackToThePauseAndKeepsRecording() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        let handle = try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 3)
        speak(handle.router, from: 100, [(1, true), (0.6, false), (1.4, true)])
        handle.router.addMarker(at: Synthetic.seconds(100.5))
        handle.router.addMarker(at: Synthetic.seconds(102.5))
        handle.router.recordBubble(center: CGPoint(x: 50, y: 50), visible: true, at: Synthetic.seconds(102.8))
        clock.set(103)
        let (duration, cut) = try await session.retake()
        #expect(abs(duration - 1.2) < 0.03, "kept \(duration) s")
        #expect(abs(cut - 101.2) < 0.05, "cut at host \(cut) s")
        try await source.emitScreen(from: 103, seconds: 1)
        clock.set(104)
        let bundle = try await session.stop().bundle
        let project = try bundle.readProject()
        #expect(project.segments.count == 2)
        #expect(abs(project.segments[0].duration - 1.2) < 0.03)
        #expect(try bundle.readMarkers().map(\.t) == [0.5])
        #expect(!project.camera.keyframes.contains { $0.t > 1.25 && $0.t < 2.5 }, "keyframes after the cut are dropped")
    }

    @Test func retakeFindsThePauseThroughEchoCancellationWhenSpeechJustResumed() async throws {
        // Echo removal on, no system audio playing: the canceller holds the newest speech while it waits for a
        // reference. The retake must still see that the pause ended, and cut back to it — not drop the take.
        let (session, clock) = makeSession()
        let echoing = RecordingConfig(
            target: .display, captureRect: CGRect(x: 0, y: 0, width: 100, height: 100), sourcePixelSize: PixelSize(width: 64, height: 40),
            resolution: .native, codec: .h264, systemAudio: true, microphone: true, echoCancellation: true)
        let fake = Mutex<FakeSource?>(nil)
        let handle = try await session.start(config: echoing, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 2)
        speak(handle.router, from: 100, [(1, true), (0.6, false), (0.12, true)])
        clock.set(101.72)
        let (duration, _) = try await session.retake()
        #expect(abs(duration - 1.2) < 0.05, "kept \(duration) s")
        _ = try await session.stop()
    }

    @Test func stoppingWhilePausedKeepsTheCursorThePauseWrote() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        let handle = try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        clock.set(101)
        try await session.pause()  // writes cursor.json in the background…
        _ = try await session.stop()  // …and the stop waits for it
        let cursor = try handle.bundle.readCursor()
        #expect(!cursor.samples.isEmpty && cursor.samples == handle.router.cursor.samples)
    }

    @Test func retakeWithoutAPauseDropsTheWholeSegment() async throws {
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        let handle = try await session.start(config: config, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 2)
        speak(handle.router, from: 100, [(2, true)])
        clock.set(102)
        #expect(try await session.retake().duration == 0)
        #expect(!FileManager.default.fileExists(atPath: handle.bundle.segmentURL("segment-000.mov").path))
        try await source.emitScreen(from: 102, seconds: 1)
        clock.set(103)
        let project = try await session.stop().bundle.readProject()
        #expect(project.segments.map(\.file) == ["segment-001.mov"])
    }

    @Test func bubbleKeyframesAndStyleReachTheManifest() async throws {
        var withCamera = config
        withCamera.camera = true
        let (session, clock) = makeSession()
        let fake = Mutex<FakeSource?>(nil)
        let handle = try await session.start(config: withCamera, in: Synthetic.temporaryFolder()) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        let source = try #require(fake.withLock { $0 })
        try await source.emitScreen(from: 100, seconds: 1)
        handle.router.recordBubble(center: CGPoint(x: 25, y: 75), visible: true, at: Synthetic.seconds(100.5))
        handle.router.setBubble(size: 0.12, shape: .rounded)
        clock.set(101)
        let project = try await session.stop().bundle.readProject()
        #expect(project.camera.enabled)
        #expect(project.camera.size == 0.12 && project.camera.shape == .rounded)
        #expect(project.camera.keyframes.last.map { [$0.t, $0.x, $0.y] } == [0.5, 0.25, 0.75])
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
        let s = Task { try await session.stop().bundle }
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

        async let first = attempt { try await session.stop().bundle }
        let second = await attempt { try await session.stop().bundle }
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

    @Test func bubbleMovesAreKeyframedOnTheEditedTimeline() throws {
        let router = FrameRouter(
            captureRect: CGRect(x: 100, y: 0, width: 400, height: 200), camera: Project.Camera(enabled: true, size: 0.1, keyframes: [])
        ) { CGPoint(x: 0, y: 0) }
        // Placed before recording starts: t = 0.
        router.recordBubble(center: CGPoint(x: 300, y: 100), visible: true, at: Synthetic.seconds(40))
        let writer = try SegmentWriter(
            url: Synthetic.temporaryFolder().appending(path: "s.mov"),
            config: WriterConfig(
                tracks: [.screen], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
        router.attach(writer, offset: 10)
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        router.recordBubble(center: CGPoint(x: 150, y: 50), visible: true, at: Synthetic.seconds(52))
        router.recordBubble(center: CGPoint(x: 150, y: 50), visible: false, at: Synthetic.seconds(55))
        router.setBubble(size: 0.2, shape: .square)
        let camera = router.camera
        #expect(camera.keyframes.map(\.t) == [0, 12, 15])
        #expect(camera.keyframes[0].x == 0.5 && camera.keyframes[0].y == 0.5)
        #expect(camera.keyframes[1].x == 0.125 && camera.keyframes[1].y == 0.25)
        #expect(camera.keyframes.map(\.visible) == [true, true, false])
        #expect(camera.size == 0.2 && camera.shape == .square)
    }

    @Test func theMicListenerHearsWhatTheMicTrackGetsWhileRecording() async throws {
        for cancelsEcho in [false, true] {
            let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100), cancelsEcho: cancelsEcho) {
                CGPoint(x: 50, y: 50)
            }
            let heard = Mutex<[MicAudio]>([])
            router.setMicListener { audio in heard.withLock { $0.append(audio) } }
            let mic = Synthetic.audio(pts: Synthetic.seconds(49), samples: [Float](repeating: 0.1, count: 1024), channels: 1)
            router.receive(mic, kind: .mic)  // before recording: not heard
            let tracks: [TrackKind] = cancelsEcho ? [.screen, .system, .mic, .micRaw] : [.screen, .mic]
            let writer = try SegmentWriter(
                url: Synthetic.temporaryFolder().appending(path: "s.mov"),
                config: WriterConfig(
                    tracks: tracks, screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
            router.attach(writer, offset: 0)
            router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
            for i in 0..<20 {
                let pts = Synthetic.seconds(50 + Double(i * 1024) / 48_000)
                router.receive(Synthetic.audio(pts: pts, samples: [Float](repeating: 0.1, count: 2048), channels: 2), kind: .mic)
            }
            router.attach(nil, offset: 0)
            router.receive(
                Synthetic.audio(pts: Synthetic.seconds(60), samples: [Float](repeating: 0.1, count: 1024), channels: 1), kind: .mic)
            let audio = heard.withLock { $0 }
            let count = audio.reduce(0) { $0 + $1.samples.count }
            #expect(audio.first.map { abs($0.hostTime - 50) < 0.02 } == true, "starts at the recording, cancelsEcho \(cancelsEcho)")
            // Everything recorded is heard (the echo path flushes its last samples at the segment's end).
            #expect(abs(count - 20 * 1024) <= 1024, "heard \(count) samples, cancelsEcho \(cancelsEcho)")
            #expect(audio.allSatisfy { $0.hostTime < 59 }, "nothing after the segment ended")
            _ = try await writer.finish(at: Synthetic.seconds(51))
        }
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

    struct EchoSegment {
        var tracks: [TrackKind]
        /// Decoded mono samples of `mic` and `micRaw`.
        var mic: [Float]
        var raw: [Float]
    }

    /// Records ~4 s of speaker echo through a router with cancellation on. `splitAt` switches to a second segment
    /// at that chunk (like a pause); `monoFrom` makes the microphone mono from that chunk on (a headset connecting).
    /// A loud click only the microphone hears is placed at sample `click`, to check `mic` and `micRaw` line up.
    func recordEcho(splitAt: Int? = nil, monoFrom: Int = .max, click: Int = 48_000 * 3) async throws -> [EchoSegment] {
        let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100), cancelsEcho: true) { CGPoint(x: 50, y: 50) }
        let config = WriterConfig(
            tracks: [.screen, .system, .mic, .micRaw], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30,
            videoBitrate: 500_000)
        var urls = [Synthetic.temporaryFolder().appending(path: "s0.mov")]
        var writers = [try SegmentWriter(url: urls[0], config: config)]
        router.attach(writers[0], offset: 0)
        let chunks = 188
        let far = EchoCancellerTests.noise(count: chunks * 1024)
        var mic = EchoCancellerTests.echoOf(far)
        for i in click..<click + 48 { mic[i] += 0.9 }
        func seconds(_ i: Int) -> Double { 50 + Double(i * 1024) / 48_000 }
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        for i in 0..<chunks {
            if i == splitAt {
                router.attach(nil, offset: 0)
                _ = try await writers[0].finish(at: Synthetic.seconds(seconds(i)))
                urls.append(Synthetic.temporaryFolder().appending(path: "s1.mov"))
                writers.append(try SegmentWriter(url: urls[1], config: config))
                router.attach(writers[1], offset: 0)
                router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(seconds(i)), rgb: (0, 0, 0)), kind: .screen)
            }
            let range = i * 1024..<(i + 1) * 1024
            let pts = Synthetic.seconds(seconds(i))
            router.receive(Synthetic.audio(pts: pts, samples: EchoCancellerTests.stereo(far[range]), channels: 2), kind: .system)
            let micBuffer =
                i >= monoFrom
                ? Synthetic.audio(pts: pts, samples: Array(mic[range]), channels: 1)
                : Synthetic.audio(pts: pts, samples: EchoCancellerTests.stereo(mic[range]), channels: 2)
            router.receive(micBuffer, kind: .mic)
            if i % 3 == 0 {
                router.receive(Synthetic.video(width: 64, height: 40, pts: pts, rgb: (0, 0, 0)), kind: .screen)
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        router.attach(nil, offset: 0)
        _ = try await writers.last!.finish(at: Synthetic.seconds(seconds(chunks)))
        var segments: [EchoSegment] = []
        for (url, writer) in zip(urls, writers) {
            let asset = AVURLAsset(url: url)
            let audio = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
            segments.append(
                EchoSegment(
                    tracks: writer.writtenTracks,
                    mic: try EchoRecordingTests.mono(EchoRecordingTests.buffers(of: audio[1], in: asset)).samples,
                    raw: try EchoRecordingTests.mono(EchoRecordingTests.buffers(of: audio[2], in: asset)).samples))
        }
        return segments
    }

    /// Echo removed in the file, in dB, after the canceller has converged (and past AAC's own error).
    func erle(_ segment: EchoSegment, from: Int = 48_000) -> Double {
        let end = min(segment.mic.count, segment.raw.count)
        guard end > from else { return 0 }
        return 10 * log10(EchoCancellerTests.power(segment.raw[from..<end]) / max(EchoCancellerTests.power(segment.mic[from..<end]), 1e-20))
    }

    /// Sample index of the loudest moment: the click, which the canceller keeps (the system audio never had it).
    func click(in samples: [Float]) -> Int { samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? -1 }

    @Test func echoCancellationWritesCleanedAndRawMicrophone() async throws {
        let segment = try #require(try await recordEcho().first)
        #expect(segment.tracks == [.screen, .system, .mic, .micRaw])
        #expect(segment.mic.count == segment.raw.count)
        #expect(
            abs(click(in: segment.mic) - click(in: segment.raw)) <= 48, "click at \(click(in: segment.mic)) vs \(click(in: segment.raw))")
        #expect(erle(segment) >= 15, "echo removed in the file: \(erle(segment)) dB")
    }

    @Test func eachSegmentGetsExactlyItsOwnCleanedMicrophone() async throws {
        let segments = try await recordEcho(splitAt: 94, click: 150 * 1024)
        #expect(segments.count == 2)
        for segment in segments {
            #expect(segment.mic.count == segment.raw.count, "mic \(segment.mic.count) vs raw \(segment.raw.count) samples")
        }
        let second = segments[1]
        #expect(abs(click(in: second.mic) - click(in: second.raw)) <= 48, "click at \(click(in: second.mic)) vs \(click(in: second.raw))")
        #expect(erle(segments[1]) >= 15, "echo removed after the switch: \(erle(segments[1])) dB")
    }

    @Test func aMicrophoneFormatChangeKeepsCancelling() async throws {
        let segment = try #require(try await recordEcho(monoFrom: 94, click: 150 * 1024).first)
        #expect(segment.mic.count == segment.raw.count)
        #expect(
            abs(click(in: segment.mic) - click(in: segment.raw)) <= 48, "click at \(click(in: segment.mic)) vs \(click(in: segment.raw))")
        #expect(erle(segment, from: 48_000 * 3) >= 15, "echo removed after the switch: \(erle(segment, from: 48_000 * 3)) dB")
    }
}
