import CoreGraphics
import Foundation
import ProjectKit
import Synchronization
import TestSupport
import Testing

@testable import CaptureKit

struct StreamBroke: Error {}

@Suite struct CaptureEventTests {
    let config = RecordingConfig(
        target: .display, captureRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        sourcePixelSize: PixelSize(width: 64, height: 40), resolution: .native,
        codec: .h264, systemAudio: false, microphone: true
    )

    func startWithFake(_ session: CaptureSession, in folder: URL) async throws -> (RecordingHandle, FakeSource) {
        let fake = Mutex<FakeSource?>(nil)
        let handle = try await session.start(config: config, in: folder) { router in
            let source = FakeSource(router: router)
            fake.withLock { $0 = source }
            return [source]
        }
        return (handle, try #require(fake.withLock { $0 }))
    }

    @Test func sidecarIsWrittenForEverySegment() async throws {
        let clock = FakeClock()
        let session = CaptureSession(now: clock.now, cursorLocation: { CGPoint(x: 50, y: 50) })
        let (handle, source) = try await startWithFake(session, in: Synthetic.temporaryFolder())
        #expect(try handle.bundle.readSidecar(for: "segment-000.mov") == [.screen, .mic])
        try await source.emitScreen(from: 100, seconds: 0.5)
        clock.set(100.5)
        try await session.pause()
        clock.set(200)
        try await session.resume()
        #expect(try handle.bundle.readSidecar(for: "segment-001.mov") == [.screen, .mic])
        clock.set(201)
        _ = try await session.stop()
    }

    @Test func streamStopIsReportedWithTheRecordingID() async throws {
        let session = CaptureSession(cursorLocation: { nil })
        let (handle, _) = try await startWithFake(session, in: Synthetic.temporaryFolder())
        handle.router.reportStreamStopped(StreamBroke(), userInitiated: false)
        var iterator = session.events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.recordingID == handle.id)
        #expect(event.kind == .streamStopped(userInitiated: false))
        #expect(event.error is StreamBroke)
        _ = try await session.stop()
    }

    @Test func eachRecordingGetsANewID() async throws {
        let session = CaptureSession(cursorLocation: { nil })
        let folder = Synthetic.temporaryFolder()
        let (first, _) = try await startWithFake(session, in: folder)
        _ = try await session.stop()
        let (second, _) = try await startWithFake(session, in: folder)
        _ = try await session.stop()
        #expect(second.id == first.id + 1)
    }

    @Test(.timeLimit(.minutes(1))) func eventsEndWhenTheSessionIsReleased() async {
        var session: CaptureSession? = CaptureSession(cursorLocation: { nil })
        let events = session!.events
        session = nil
        var received = 0
        for await _ in events { received += 1 }  // must finish, not hang
        #expect(received == 0)
    }
}

@Suite struct CursorDiscardTests {
    @Test func discardsSamplesAndClicksFromOffset() throws {
        let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100)) { CGPoint(x: 10, y: 10) }
        let url = Synthetic.temporaryFolder().appending(path: "s.mov")
        let writer = try SegmentWriter(
            url: url,
            config: WriterConfig(
                tracks: [.screen], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
        router.attach(writer, offset: 5)
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        router.recordClick(at: Synthetic.seconds(50.1))
        #expect(router.cursor.samples.count == 1)
        router.discard(from: 5)
        #expect(router.cursor.samples.isEmpty)
        #expect(router.cursor.clicks.isEmpty)
    }

    @Test func aClickIsRecordedWhereItHappenedNotWhereTheCursorIsNow() throws {
        let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100)) { CGPoint(x: 90, y: 90) }  // moved on
        let writer = try SegmentWriter(
            url: Synthetic.temporaryFolder().appending(path: "s.mov"),
            config: WriterConfig(
                tracks: [.screen], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
        router.attach(writer, offset: 0)
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        router.recordClick(at: Synthetic.seconds(50.1), location: CGPoint(x: 20, y: 30))
        router.recordClick(at: Synthetic.seconds(50.2))
        #expect(router.cursor.clicks.map(\.x) == [0.2, 0.9] && router.cursor.clicks.map(\.y) == [0.3, 0.9])
    }

    @Test func clicksFollowAMovedWindow() throws {
        let router = FrameRouter(captureRect: CGRect(x: 0, y: 0, width: 100, height: 100)) { nil }
        let writer = try SegmentWriter(
            url: Synthetic.temporaryFolder().appending(path: "s.mov"),
            config: WriterConfig(
                tracks: [.screen], screenSize: PixelSize(width: 64, height: 40), codec: .h264, fps: 30, videoBitrate: 500_000))
        router.attach(writer, offset: 0)
        router.receive(Synthetic.video(width: 64, height: 40, pts: Synthetic.seconds(50), rgb: (0, 0, 0)), kind: .screen)
        router.recordClick(at: Synthetic.seconds(50.1), location: CGPoint(x: 50, y: 50))
        router.follow(area: CGRect(x: 200, y: 100, width: 100, height: 100))  // the window was dragged
        router.recordClick(at: Synthetic.seconds(50.2), location: CGPoint(x: 250, y: 150))
        router.follow(area: .zero)  // ignored
        #expect(router.cursor.clicks.map(\.x) == [0.5, 0.5] && router.cursor.clicks.map(\.y) == [0.5, 0.5])
    }
}
