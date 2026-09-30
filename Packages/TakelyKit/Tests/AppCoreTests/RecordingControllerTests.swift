import CaptureKit
import CoreGraphics
import Foundation
import ProjectKit
import Synchronization
import TestSupport
import Testing

@testable import AppCore

struct Broke: Error, LocalizedError {
    var errorDescription: String? { "The display was disconnected." }
}

@MainActor
final class FakeSession: RecordingSession {
    let events: AsyncStream<CaptureEvent>
    let sink: AsyncStream<CaptureEvent>.Continuation
    var calls: [String] = []
    var startError: (any Error)?
    var pauseError: (any Error)?
    /// Reported by `stop` as a failure closing the last segment; the bundle is still returned.
    var closeFailure: (any Error)?
    /// Makes pause take a while, so a test can hold the controller busy.
    var pauseDelay: Duration = .zero
    /// Makes start/stop take a while, to open the window for overlapping commands.
    var delay: Duration = .zero
    var engineState: CaptureSession.State = .idle
    private(set) var handles: [RecordingHandle] = []
    private var nextID = 0

    init() { (events, sink) = AsyncStream.makeStream(of: CaptureEvent.self) }

    func start(in folder: URL) async throws -> RecordingHandle {
        calls.append("start")
        try await Task.sleep(for: delay)
        if let startError { throw startError }
        nextID += 1
        let bundle = try ProjectBundle.create(in: folder, date: Date(timeIntervalSince1970: Double(nextID)))
        try bundle.write(
            Project(
                capture: .init(target: .display, pixelSize: PixelSize(width: 64, height: 40), fps: 30, codec: .h264),
                camera: .init(enabled: false)))
        let handle = RecordingHandle(id: nextID, bundle: bundle, router: FrameRouter(captureRect: .zero))
        handles.append(handle)
        engineState = .recording
        return handle
    }

    func pause() async throws {
        calls.append("pause")
        try await Task.sleep(for: pauseDelay)
        if let pauseError { throw pauseError }
        engineState = .paused
    }

    func resume() async throws {
        calls.append("resume")
        engineState = .recording
    }

    func stop() async throws -> StoppedRecording {
        calls.append("stop")
        try await Task.sleep(for: delay)
        engineState = .idle
        var project = try handles.last!.bundle.readProject()
        project.status = .finished
        project.segments = [.init(file: "segment-000.mov", duration: 83, tracks: [.screen])]
        try handles.last!.bundle.write(project)
        return StoppedRecording(bundle: handles.last!.bundle, failure: closeFailure)
    }

    func state() async -> CaptureSession.State { engineState }

    func emit(_ kind: CaptureEvent.Kind, for id: Int) {
        sink.yield(CaptureEvent(recordingID: id, kind: kind, error: Broke()))
    }
}

final class FakeExporter: Exporting {
    let failing = Mutex(false)
    let count = Mutex(0)
    let delay = Mutex(Duration.zero)
    func export(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await Task.sleep(for: delay.withLock { $0 })
        count.withLock { $0 += 1 }
        if failing.withLock({ $0 }) { throw Broke() }
        progress(1)
        return bundle.exportURL
    }
}

@MainActor
final class FakeFeedback: RecordingFeedback {
    var ready: [(URL, Double)] = []
    var announcements: [String] = []
    var failures: [String] = []
    /// Makes posting the Ready notification take a while, like the real one checking notification settings.
    var readyDelay: Duration = .zero
    func recordingReady(_ url: URL, duration: Double) async {
        try? await Task.sleep(for: readyDelay)
        ready.append((url, duration))
    }
    func recordingFailed(_ message: String) async { failures.append(message) }
    func announce(_ message: String) { announcements.append(message) }
}

final class FakeDisk: DiskSpace {
    let free = Mutex<Int64>(100_000_000_000)
    let used = Mutex<Int64>(0)
    func freeBytes(at url: URL) throws -> Int64 { free.withLock { $0 } }
    func usedBytes(at url: URL) -> Int64 { used.withLock { $0 } }
}

final class FakeTime: Sendable {
    let offset = Mutex(Duration.zero)
    let base = ContinuousClock.now
    func advance(_ d: Duration) { offset.withLock { $0 += d } }
    var now: @Sendable () -> ContinuousClock.Instant { { self.base + self.offset.withLock { $0 } } }
}

@MainActor
struct Harness {
    let session = FakeSession()
    let exporter = FakeExporter()
    let feedback = FakeFeedback()
    let disk = FakeDisk()
    let time = FakeTime()
    let folder = Synthetic.temporaryFolder()
    let controller: RecordingController

    init() {
        let folder = folder
        controller = RecordingController(
            session: session, exporter: exporter, feedback: feedback, disk: disk,
            saveFolder: { folder }, now: time.now,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })  // loops stay idle; tests call checkStorage directly
    }

    /// Lets queued tasks (event loop, pending-failure handling) run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite struct RecordingControllerTests {
    @Test func startThenStopExportsAndReportsReady() async {
        let h = Harness()
        await h.controller.start()
        #expect(h.controller.phase == .recording)
        await h.controller.stop()
        #expect(h.controller.phase == .idle)
        #expect(h.session.calls == ["start", "stop"])
        #expect(h.feedback.ready.first?.1 == 83)
        #expect(h.controller.lastRecording == h.session.handles[0].bundle.exportURL)
        #expect(h.feedback.announcements == ["Recording started", "Recording stopped"])
        #expect(h.feedback.failures.isEmpty)
    }

    @Test func failedStartIsSentAsFeedback() async {
        let h = Harness()
        h.session.startError = Broke()
        await h.controller.start()
        #expect(h.controller.phase == .idle)
        #expect(h.feedback.failures == ["Couldn't start recording: The display was disconnected."])
    }

    @Test func refusesToStartWithLessThanTwoGigabytes() async {
        let h = Harness()
        h.disk.free.withLock { $0 = 1_200_000_000 }
        await h.controller.start()
        #expect(h.session.calls.isEmpty)
        #expect(h.controller.phase == .idle)
        #expect(h.controller.errorMessage?.contains("Not enough space") == true)
    }

    @Test func storageCheckStopsWhenTheExportWouldNotFit() async {
        let h = Harness()
        await h.controller.start()
        h.disk.used.withLock { $0 = 3_000_000_000 }
        h.disk.free.withLock { $0 = 3_600_000_000 }
        await h.controller.checkStorage()
        #expect(h.controller.isRecording)
        h.disk.free.withLock { $0 = 3_400_000_000 }
        await h.controller.checkStorage()
        #expect(h.controller.phase == .idle)
        #expect(h.session.calls == ["start", "stop"])
        #expect(h.exporter.count.withLock { $0 } == 1)
        #expect(h.controller.errorMessage == "Stopped: disk almost full — recording saved.")
        #expect(h.feedback.failures == ["Stopped: disk almost full — recording saved."])
        #expect(h.feedback.ready.isEmpty)
    }

    @Test func writerFailureStopsSavesAndExplains() async {
        let h = Harness()
        await h.controller.start()
        h.session.emit(.writerFailed, for: 1)
        await h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.session.calls == ["start", "stop"])
        #expect(h.exporter.count.withLock { $0 } == 1)
        #expect(h.controller.errorMessage == "Recording stopped: The display was disconnected. Saved up to 1:23.")
        #expect(h.feedback.failures == ["Recording stopped: The display was disconnected. Saved up to 1:23."])
        #expect(h.feedback.ready.isEmpty)  // the failure is sent instead of "Recording ready"
    }

    @Test func lastSegmentCloseFailureIsExplainedAndTheRestExported() async {
        let h = Harness()
        await h.controller.start()
        h.session.closeFailure = Broke()
        await h.controller.stop()
        #expect(h.controller.errorMessage == "Recording stopped: The display was disconnected. Saved up to 1:23.")
        #expect(h.exporter.count.withLock { $0 } == 1)
        #expect(h.controller.lastRecording == h.session.handles[0].bundle.exportURL)
        #expect(h.feedback.failures == ["Recording stopped: The display was disconnected. Saved up to 1:23."])
        #expect(h.feedback.ready.isEmpty)
    }

    @Test func writerFailureMessageWinsOverTheCloseFailureItCauses() async {
        let h = Harness()
        await h.controller.start()
        h.session.closeFailure = CaptureError.writerFailed("finishWriting failed")
        h.session.emit(.writerFailed, for: 1)
        await h.settle()
        #expect(h.feedback.failures == ["Recording stopped: The display was disconnected. Saved up to 1:23."])
    }

    @Test func systemStopSharingStopsWithoutAnError() async {
        let h = Harness()
        await h.controller.start()
        h.session.emit(.streamStopped(userInitiated: true), for: 1)
        await h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.errorMessage == nil)
        #expect(h.feedback.ready.count == 1)
    }

    @Test func lateEventFromAnEarlierRecordingIsIgnored() async {
        let h = Harness()
        await h.controller.start()
        await h.controller.stop()
        await h.controller.start()
        h.session.emit(.streamStopped(userInitiated: false), for: 1)  // recording 1 is long gone
        await h.settle()
        #expect(h.controller.isRecording)
        #expect(h.session.calls == ["start", "stop", "start"])
    }

    @Test func failureDuringStartIsHandledOnceStartReturns() async {
        let h = Harness()
        h.session.delay = .milliseconds(100)
        async let started: Void = h.controller.start()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.controller.phase == .starting)
        // The new recording (ID 1) fails before `start` has even returned its handle.
        h.session.emit(.streamStopped(userInitiated: false), for: 1)
        h.session.delay = .zero  // the in-flight start already read its delay; the queued stop should be quick
        await h.settle()
        #expect(h.session.calls == ["start"])
        await started
        await h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.session.calls == ["start", "stop"])
        #expect(h.controller.errorMessage == "Recording stopped: The display was disconnected.")
    }

    @Test func failureDuringACommandIsHandledRightAfter() async {
        let h = Harness()
        await h.controller.start()
        h.session.pauseDelay = .milliseconds(100)
        async let paused: Void = h.controller.togglePause()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.controller.isBusy)  // the pause is in flight, so the event must wait for it
        h.session.emit(.streamStopped(userInitiated: false), for: 1)
        await h.settle()
        #expect(h.session.calls == ["start", "pause"])
        await paused
        await h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.session.calls == ["start", "pause", "stop"])
        #expect(h.controller.errorMessage == "Recording stopped: The display was disconnected.")
    }

    @Test func overlappingStopsRunOnce() async {
        let h = Harness()
        await h.controller.start()
        h.session.delay = .milliseconds(80)
        async let a: Void = h.controller.stop()
        async let b: Void = h.controller.stop()
        _ = await (a, b)
        #expect(h.session.calls == ["start", "stop"])
        #expect(h.exporter.count.withLock { $0 } == 1)
    }

    @Test func systemQuitSavesWithoutExporting() async {
        let h = Harness()
        await h.controller.start()
        await h.controller.stopForSystemQuit()
        #expect(h.session.calls == ["start", "stop"])
        #expect(h.exporter.count.withLock { $0 } == 0)
        #expect(h.feedback.ready.isEmpty)
        #expect(h.controller.phase == .idle)
    }

    @Test func exportFailureKeepsTheBundleAndSaysSo() async {
        let h = Harness()
        h.exporter.failing.withLock { $0 = true }
        await h.controller.start()
        await h.controller.stop()
        #expect(h.controller.lastRecording == h.session.handles[0].bundle.url)
        #expect(h.controller.errorMessage?.hasPrefix("Recording saved, but export failed") == true)
        #expect(h.feedback.failures == [h.controller.errorMessage])
        #expect(h.feedback.ready.isEmpty)
    }

    @Test func failedPauseResyncsFromTheEngine() async {
        let h = Harness()
        await h.controller.start()
        h.session.pauseError = Broke()
        h.session.engineState = .paused  // the engine paused anyway
        await h.controller.togglePause()
        #expect(h.controller.phase == .paused)
        #expect(h.controller.errorMessage?.hasPrefix("Couldn't pause or resume") == true)
    }

    @Test func elapsedExcludesPausedTime() async {
        let h = Harness()
        await h.controller.start()
        h.time.advance(.seconds(10))
        await h.controller.togglePause()
        #expect(h.controller.elapsed == .seconds(10))
        h.time.advance(.seconds(30))
        await h.controller.togglePause()
        h.time.advance(.seconds(5))
        await h.controller.togglePause()
        #expect(h.controller.elapsed == .seconds(15))
    }

    @Test func exportsARecoveredBundle() async throws {
        let h = Harness()
        let bundle = try ProjectBundle.create(in: h.folder)
        try bundle.write(
            Project(
                status: .finished, capture: .init(target: .display, pixelSize: PixelSize(width: 64, height: 40), fps: 30, codec: .h264),
                camera: .init(enabled: false)))
        await h.controller.export(bundle)
        #expect(h.exporter.count.withLock { $0 } == 1)
        #expect(h.controller.lastRecording == bundle.exportURL)
        #expect(h.controller.phase == .idle)
    }

    @Test func staleErrorDoesNotHideALaterFailure() async {
        let h = Harness()
        await h.controller.start()
        h.session.pauseError = Broke()
        h.session.engineState = .recording  // the engine stayed recording, so togglePause resyncs to it
        await h.controller.togglePause()
        #expect(h.controller.errorMessage?.hasPrefix("Couldn't pause or resume") == true)
        h.session.emit(.writerFailed, for: 1)
        await h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.errorMessage == "Recording stopped: The display was disconnected. Saved up to 1:23.")
    }

    @Test func diskFullStopKeepsAnExportFailureVisible() async {
        let h = Harness()
        h.exporter.failing.withLock { $0 = true }
        await h.controller.start()
        h.disk.used.withLock { $0 = 3_000_000_000 }
        h.disk.free.withLock { $0 = 3_400_000_000 }
        await h.controller.checkStorage()
        #expect(h.controller.errorMessage?.hasPrefix("Stopped: disk almost full.") == true)
        #expect(h.controller.errorMessage?.contains("export failed") == true)
    }

    @Test func quitWaitsForARunningCommandThenStops() async {
        let h = Harness()
        await h.controller.start()
        h.session.pauseDelay = .milliseconds(100)
        async let p: Void = h.controller.togglePause()
        try? await Task.sleep(for: .milliseconds(30))
        await h.controller.stopForQuit(system: true)
        await p
        #expect(h.session.calls == ["start", "pause", "stop"])
        #expect(h.controller.phase == .idle)
        #expect(h.exporter.count.withLock { $0 } == 0)
    }

    @Test func exportWhileRecordingIsRefusedWithAMessage() async throws {
        let h = Harness()
        await h.controller.start()
        let bundle = try ProjectBundle.create(in: h.folder)
        try bundle.write(
            Project(
                status: .finished, capture: .init(target: .display, pixelSize: PixelSize(width: 64, height: 40), fps: 30, codec: .h264),
                camera: .init(enabled: false)))
        await h.controller.export(bundle)
        #expect(h.exporter.count.withLock { $0 } == 0)
        #expect(h.controller.errorMessage == "Finish the current recording first.")
    }

    @Test func systemQuitDoesNotWaitForAnExport() async {
        let h = Harness()
        h.exporter.delay.withLock { $0 = .milliseconds(300) }
        await h.controller.start()
        async let stopped: Void = h.controller.stop()
        try? await Task.sleep(for: .milliseconds(30))
        guard case .exporting = h.controller.phase else { Issue.record("expected exporting"); return }
        let began = ContinuousClock.now
        await h.controller.stopForQuit(system: true)
        #expect(ContinuousClock.now - began < .milliseconds(150))  // returned without waiting for the export
        await stopped
    }

    @Test func userQuitWaitsForTheExport() async {
        let h = Harness()
        h.exporter.delay.withLock { $0 = .milliseconds(150) }
        await h.controller.start()
        async let stopped: Void = h.controller.stop()
        try? await Task.sleep(for: .milliseconds(30))
        await h.controller.stopForQuit(system: false)
        #expect(h.controller.phase == .idle)
        #expect(h.exporter.count.withLock { $0 } == 1)
        await stopped
    }

    @Test func stopReturnsOnlyAfterTheReadyNotificationIsPosted() async {
        let h = Harness()
        h.feedback.readyDelay = .milliseconds(100)
        await h.controller.start()
        await h.controller.stop()
        #expect(h.feedback.ready.count == 1)
    }

    @Test func userQuitWaitsForTheReadyNotification() async {
        let h = Harness()
        h.exporter.delay.withLock { $0 = .milliseconds(100) }
        h.feedback.readyDelay = .milliseconds(100)
        await h.controller.start()
        async let stopped: Void = h.controller.stop()
        try? await Task.sleep(for: .milliseconds(30))
        await h.controller.stopForQuit(system: false)
        #expect(h.feedback.ready.count == 1)  // the app replies to terminate right after this
        await stopped
    }
}
