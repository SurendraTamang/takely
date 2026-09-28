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
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    private var current: RecordingHandle?
    /// Events that arrived while a command ran, in order; their recording IDs are checked when handled.
    private var pending: [CaptureEvent] = []
    private var accumulated: Duration = .zero
    private var runningSince: ContinuousClock.Instant?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var storageLoop: Task<Void, Never>?
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    private let log = Logger(subsystem: "app.takely", category: "controller")

    public init(
        session: any RecordingSession,
        exporter: any Exporting,
        feedback: any RecordingFeedback,
        disk: any DiskSpace = SystemDiskSpace(),
        saveFolder: @escaping @MainActor () -> URL,
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
                errorMessage = "Not enough space: \(Self.size(free)) free, \(Self.size(StorageGuard.minimumFreeToStart)) needed."
                return
            }
            phase = .starting
            current = try await session.start(in: folder)
            phase = .recording
            accumulated = .zero
            startTicking()
            startStorageLoop()
            feedback.announce("Recording started")
        } catch {
            log.error("start failed: \(error.localizedDescription)")
            phase = .idle
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
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
        _ = await performStop(export: true)
    }

    /// For logout/restart/update: saves the recording but skips the export, which recovery offers next launch.
    public func stopForSystemQuit() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        _ = await performStop(export: false)
    }

    /// Exports a recovered or unexported bundle, reporting like a normal stop.
    public func export(_ bundle: ProjectBundle) async {
        guard phase == .idle, !isBusy else { return }
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
        _ = await performStop(export: true)
        errorMessage = "Stopped: disk almost full — recording saved."
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
        let bundle = await performStop(export: true)
        guard errorMessage == nil else { return }
        switch event.kind {
        case .streamStopped(userInitiated: true):
            break  // the system "Stop sharing" control: an intentional stop
        case .streamStopped:
            errorMessage = "Recording stopped: \(event.error.localizedDescription)"
        case .writerFailed:
            let saved = bundle.flatMap { try? $0.readProject().duration } ?? 0
            errorMessage = "Recording stopped: \(event.error.localizedDescription) Saved up to \(Self.clock(saved))."
        }
    }

    // MARK: Internals

    private func performStop(export: Bool) async -> ProjectBundle? {
        phase = .stopping
        stopTicking()
        storageLoop?.cancel()
        let bundle: ProjectBundle
        do {
            bundle = try await session.stop()
        } catch {
            log.error("stop failed: \(error.localizedDescription)")
            errorMessage = "Couldn't stop recording: \(error.localizedDescription)"
            finishRecording()
            return nil
        }
        feedback.announce("Recording stopped")
        if export { await exportAndReport(bundle) }
        finishRecording()
        return bundle
    }

    private func exportAndReport(_ bundle: ProjectBundle) async {
        phase = .exporting(0)
        do {
            let url = try await exporter.export(bundle) { progress in
                Task { @MainActor [weak self] in
                    if case .exporting = self?.phase { self?.phase = .exporting(progress) }
                }
            }
            lastRecording = url
            feedback.recordingReady(url, duration: (try? bundle.readProject().duration) ?? 0)
        } catch {
            log.error("export failed: \(error.localizedDescription)")
            lastRecording = bundle.url
            errorMessage = "Recording saved, but export failed: \(error.localizedDescription)"
        }
        phase = .idle
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
        guard !pending.isEmpty else { return }
        let events = pending
        pending = []
        Task {
            for event in events { await handle(event) }
        }
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
