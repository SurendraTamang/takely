import CaptureKit
import Foundation
import OSLog
import Observation
import ProjectKit

/// The single place every trigger (menu, hotkeys, quit, recovery, later automation) goes through to
/// start, pause and stop recordings. One busy guard serializes those commands; a failure event that
/// arrives mid-command is handled right after it.
@MainActor @Observable
public final class RecordingController {
    public enum Phase: Equatable, Sendable {
        case idle, starting, recording, paused, stopping
        case exporting(Double)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var elapsed: Duration = .zero
    public var errorMessage: String?
    /// The last export, or the saved bundle if its export failed.
    public private(set) var lastRecording: URL?
    /// True while a command runs; the UI disables its buttons.
    public private(set) var isBusy = false

    public var isRecording: Bool { phase == .recording || phase == .paused }

    private let session: any RecordingSession
    private let exporter: any Exporting
    private let feedback: any RecordingFeedback
    private let disk: any DiskSpace
    private let saveFolder: @MainActor () -> URL
    private let trash: (URL) throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    @ObservationIgnored private var current: RecordingHandle?
    /// Events that arrived while a command ran; handled after the command, each re-checked against the current recording.
    @ObservationIgnored private var pending: [CaptureEvent] = []
    @ObservationIgnored private var accumulated: Duration = .zero
    @ObservationIgnored private var runningSince: ContinuousClock.Instant?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var storageLoop: Task<Void, Never>?
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var draining = 0
    private let log = Logger(subsystem: "app.takely", category: "controller")

    public init(
        session: any RecordingSession,
        exporter: any Exporting,
        feedback: any RecordingFeedback,
        disk: any DiskSpace = SystemDiskSpace(),
        saveFolder: @escaping @MainActor () -> URL,
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.exporter = exporter
        self.feedback = feedback
        self.disk = disk
        self.saveFolder = saveFolder
        self.now = now
        self.sleep = sleep
        self.trash = trash
        let events = session.events
        eventLoop = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: Commands

    public func start() async {
        guard phase == .idle, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        errorMessage = nil
        let folder = saveFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A failed space check shouldn't block recording; the writer still reports a full disk.
            if let free = try? disk.freeBytes(at: folder), !StorageGuard.canStart(freeBytes: free) {
                await report("Not enough space: \(Self.size(free)) free, \(Self.size(StorageGuard.minimumFreeToStart)) needed.")
                return
            }
            phase = .starting
            current = try await session.start(in: folder)
            phase = .recording
            accumulated = .zero
            startTicking()
            startStorageLoop()
            feedback.announce("Recording started")
        } catch is CancellationError {
            phase = .idle  // the countdown was cancelled: nothing was recorded, nothing to report
        } catch {
            log.error("start failed: \(error.localizedDescription)")
            phase = .idle
            await report("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    public func togglePause() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        do {
            if phase == .recording {
                try await session.pause()
                stopTicking()
                phase = .paused
                feedback.announce("Paused")
            } else {
                try await session.resume()
                phase = .recording
                startTicking()
                feedback.announce("Recording resumed")
            }
        } catch {
            await resyncWithEngine()
            errorMessage = "Couldn't pause or resume: \(error.localizedDescription)"
        }
    }

    /// Stops and exports; the Ready notification follows.
    public func stop() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        await performStop(export: true)
    }

    /// Oops-retake: removes the last words (back to the previous pause) and keeps recording.
    public func retake() async {
        guard phase == .recording, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        do {
            let duration = try await session.retake()
            stopTicking()
            accumulated = .seconds(duration)
            elapsed = accumulated
            startTicking()
            feedback.announce("Retake")
        } catch {
            log.error("retake failed: \(error.localizedDescription)")
            await resyncWithEngine()
            errorMessage = "Couldn't retake: \(error.localizedDescription)"
        }
    }

    /// Stops without exporting and moves the recording to the Trash.
    public func discard() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        await performDiscard()
    }

    /// Discards the current take and starts a new one (with the countdown).
    public func restart() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        await performDiscard()
        finishBusy()
        await start()
    }

    /// For logout/restart/update: saves the recording but skips the export, which recovery offers next launch.
    public func stopForSystemQuit() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        await performStop(export: false)
    }

    /// Exports a recovered or unexported bundle, reporting like a normal stop.
    public func export(_ bundle: ProjectBundle) async {
        guard !isBusy else { return }
        guard phase == .idle else {
            errorMessage = "Finish the current recording first."
            return
        }
        isBusy = true
        defer { finishBusy() }
        await exportAndReport(bundle)
    }

    /// One StorageGuard check (run every 5 s while recording): stops before the disk can't hold the export.
    public func checkStorage() async {
        guard isRecording, !isBusy, let bundle = current?.bundle,
            let free = try? disk.freeBytes(at: bundle.url)
        else { return }
        guard StorageGuard.mustStop(freeBytes: free, recordedBytes: disk.usedBytes(at: bundle.segmentsURL)) else { return }
        isBusy = true
        defer { finishBusy() }
        await performStop(export: true, cause: .diskFull)
    }

    /// Returns once no command is running and queued events are handled. Quit uses this so it never skips a stop.
    public func waitUntilIdle() async {
        while isBusy || !pending.isEmpty || draining > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    /// Like `waitUntilIdle`, but an export in progress doesn't count: a system quit mustn't wait minutes for one.
    private func waitForQuit() async {
        while (isBusy || !pending.isEmpty || draining > 0) && !isExporting {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// For quitting: waits for any running command, then stops. A user quit also waits for an export; a system
    /// quit (logout/restart) doesn't, and skips exporting: the bundle is already saved and recovery offers it next launch.
    public func stopForQuit(system: Bool) async {
        if system {
            await waitForQuit()
            if !isExporting { await stopForSystemQuit() }
        } else {
            await waitUntilIdle()
            await stop()
        }
    }

    // MARK: Events

    func handle(_ event: CaptureEvent) async {
        // Queue first: during `start` the new recording's ID isn't known until the session returns it.
        if isBusy {
            pending.append(event)
            return
        }
        guard event.recordingID == current?.id, isRecording else { return }  // e.g. a late event from an earlier recording
        isBusy = true
        defer { finishBusy() }
        await performStop(export: true, cause: .event(event))
    }

    // MARK: Internals

    /// Why a recording ended without the user pressing Stop.
    private enum StopCause {
        case diskFull
        case event(CaptureEvent)
    }

    private func performStop(export: Bool, cause: StopCause? = nil) async {
        errorMessage = nil  // a stop supersedes older messages; what follows describes this stop
        phase = .stopping
        stopTicking()
        storageLoop?.cancel()
        let stopped: StoppedRecording
        do {
            stopped = try await session.stop()
        } catch {
            log.error("stop failed: \(error.localizedDescription)")
            finishRecording()
            await report("Couldn't stop recording: \(error.localizedDescription)")
            return
        }
        feedback.announce("Recording stopped")
        let failure = Self.failureMessage(cause, closeFailure: stopped.failure, bundle: stopped.bundle)
        if export {
            var diskFull = false
            if case .diskFull = cause { diskFull = true }
            await exportAndReport(stopped.bundle, failure: failure, diskFull: diskFull)
        } else if let failure {
            await report(failure)
        }
        finishRecording()
    }

    /// What to tell the user instead of "Recording ready", or `nil` for a clean stop. The cause wins over a
    /// failed last-segment close, which a writer failure usually brings along.
    private static func failureMessage(_ cause: StopCause?, closeFailure: (any Error)?, bundle: ProjectBundle) -> String? {
        switch cause {
        case .diskFull:
            return "Stopped: disk almost full — recording saved."
        case .event(let event):
            switch event.kind {
            case .streamStopped(userInitiated: true):
                break  // the system "Stop sharing" control: an intentional stop
            case .streamStopped, .writerFailed:
                return stoppedMessage(event.error, savedIn: bundle)
            }
        case nil:
            break
        }
        return closeFailure.map { stoppedMessage($0, savedIn: bundle) }
    }

    /// For a recording cut short by a failure: what went wrong and how much was kept.
    private static func stoppedMessage(_ error: any Error, savedIn bundle: ProjectBundle) -> String {
        let saved = (try? bundle.readProject().duration) ?? 0
        return "Recording stopped: \(error.localizedDescription) Saved up to \(clock(saved))."
    }

    /// Shows `message` in the panel and sends it as a notification, for when the panel is closed.
    private func report(_ message: String) async {
        errorMessage = message
        await feedback.recordingFailed(message)
    }

    /// Exports, then sends Ready, or `failure` instead when the recording ended badly.
    private func exportAndReport(_ bundle: ProjectBundle, failure: String? = nil, diskFull: Bool = false) async {
        phase = .exporting(0)
        wakeWaiters()
        do {
            let url = try await exporter.export(bundle) { progress in
                Task { @MainActor [weak self] in
                    if case .exporting = self?.phase { self?.phase = .exporting(progress) }
                }
            }
            lastRecording = url
            if let failure {
                await report(failure)
            } else {
                await feedback.recordingReady(url, duration: (try? bundle.readProject().duration) ?? 0)
            }
        } catch {
            log.error("export failed: \(error.localizedDescription)")
            lastRecording = bundle.url
            let message = "Recording saved, but export failed: \(error.localizedDescription)"
            await report(diskFull ? "Stopped: disk almost full. \(message)" : message)
        }
        phase = .idle
    }

    private func performDiscard() async {
        errorMessage = nil
        phase = .stopping
        stopTicking()
        storageLoop?.cancel()
        do {
            let stopped = try await session.stop()
            try trash(stopped.bundle.url)
            feedback.announce("Recording discarded")
        } catch {
            log.error("discard failed: \(error.localizedDescription)")
            await report("Couldn't discard the recording: \(error.localizedDescription)")
        }
        finishRecording()
    }

    private func finishRecording() {
        current = nil
        storageLoop?.cancel()
        stopTicking()
        accumulated = .zero
        elapsed = .zero
        phase = .idle
    }

    /// After a failed pause/resume, trust the engine's state rather than the attempted transition.
    private func resyncWithEngine() async {
        switch await session.state() {
        case .paused:
            stopTicking()
            phase = .paused
        case .recording:
            if runningSince == nil { startTicking() }
            phase = .recording
        case .idle:
            finishRecording()
        }
    }

    private func finishBusy() {
        isBusy = false
        guard !pending.isEmpty else {
            wakeWaiters()
            return
        }
        let events = pending
        pending = []
        draining += 1
        Task {
            for event in events { await handle(event) }
            draining -= 1
            wakeWaiters()
        }
    }

    /// Wakes everyone waiting in `waitUntilIdle`/`waitForQuit`; each re-checks its own condition.
    private func wakeWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func startTicking() {
        let since = now()
        runningSince = since
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = self.accumulated + (self.now() - since)
                try? await self.sleep(.seconds(1))
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        if let since = runningSince {
            accumulated += now() - since
            elapsed = accumulated
        }
        runningSince = nil
    }

    private func startStorageLoop() {
        storageLoop?.cancel()
        storageLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.sleep(.seconds(5))
                guard let self, !Task.isCancelled else { return }
                await self.checkStorage()
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    static func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
