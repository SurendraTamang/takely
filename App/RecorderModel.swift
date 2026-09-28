import AVFoundation
import AppKit
import CaptureKit
import OSLog
import ProjectKit
import RenderKit
@preconcurrency import ScreenCaptureKit

/// App state for the menu bar UI. Drives `CaptureSession` and `Exporter`.
@MainActor @Observable
final class RecorderModel {
    enum Phase: Equatable {
        case idle, recording, paused
        case exporting(Double)
    }

    var phase: Phase = .idle
    var displays: [SCDisplay] = []
    var displayID: CGDirectDisplayID?
    var camera = false
    var systemAudio = true
    var microphone = true
    var resolution: Resolution = .p1080
    var fps = 30
    var codec: VideoCodec = .hevc
    private(set) var elapsed: Duration = .zero
    var errorMessage: String?
    private(set) var lastExport: URL?
    /// True when `refreshDisplays` couldn't reach ScreenCaptureKit, e.g. Screen Recording isn't granted.
    private(set) var screenPermissionDenied = false
    /// True while start/pause/resume/stop is in flight, so a second click (or a stream failure) can't race it.
    private(set) var isBusy = false

    static let saveFolder = URL.moviesDirectory.appending(path: "Takely", directoryHint: .isDirectory)

    private let session = CaptureSession()
    private var clickMonitor: Any?
    private var ticker: Task<Void, Never>?
    private var recordingStart: ContinuousClock.Instant?
    private var pendingFailure: (any Error)?
    private let log = Logger(subsystem: "app.takely", category: "app")

    /// Runs on every popover open; must never touch `errorMessage`, or a live error/stream-failure
    /// message would vanish the moment the user reopens the menu.
    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            if !displays.contains(where: { $0.displayID == displayID }) {
                displayID = displays.first?.displayID
            }
            screenPermissionDenied = false
        } catch {
            screenPermissionDenied = true
        }
    }

    func start() async {
        guard phase == .idle, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        errorMessage = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                errorMessage = "No display available."
                return
            }
            if camera, !(await AVCaptureDevice.requestAccess(for: .video)) {
                errorMessage = "Allow Camera access in System Settings, or turn the camera off."
                return
            }
            if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                errorMessage = "Allow Microphone access in System Settings, or turn the microphone off."
                return
            }
            // Exclude the app, not a window snapshot, so windows opened later (the popover) never appear.
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter =
                ownApps.isEmpty
                ? SCContentFilter(
                    display: display,
                    excludingWindows: content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
                : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let bounds = CGDisplayBounds(display.displayID)
            let scale = Double(filter.pointPixelScale)
            let config = RecordingConfig(
                target: .display,
                captureRect: bounds,
                sourcePixelSize: PixelSize(width: Int(bounds.width * scale), height: Int(bounds.height * scale)),
                resolution: resolution, fps: fps, codec: codec,
                camera: camera, systemAudio: systemAudio, microphone: microphone
            )
            try FileManager.default.createDirectory(at: Self.saveFolder, withIntermediateDirectories: true)
            let router = try await session.start(config: config, in: Self.saveFolder) { router in
                var sources: [any FrameSource] = [
                    ScreenSource(filter: filter, config: config, sourceRect: nil, router: router) { error in
                        Task { @MainActor [weak self] in await self?.streamFailed(error) }
                    }
                ]
                if config.camera { sources.append(try CameraSource(router: router)) }
                return sources
            }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                router.recordClick(at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            elapsed = .zero
            phase = .recording
            startTicker()
        } catch {
            log.error("start failed: \(error.localizedDescription)")
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func togglePause() async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        do {
            switch phase {
            case .recording:
                try await session.pause()
                if let start = recordingStart { elapsed = ContinuousClock.now - start }
                ticker?.cancel()
                phase = .paused
            case .paused:
                try await session.resume()
                phase = .recording
                startTicker()
            default:
                break
            }
        } catch {
            // The engine call is serialized but may still have failed after partially applying;
            // trust its actual state rather than assuming our attempted transition took effect.
            switch await session.state {
            case .paused:
                ticker?.cancel()
                phase = .paused
            case .recording:
                phase = .recording
            case .idle:
                ticker?.cancel()
                if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                clickMonitor = nil
                phase = .idle
            }
            errorMessage = "Couldn't pause or resume: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard phase == .recording || phase == .paused, !isBusy else { return }
        isBusy = true
        defer { finishBusy() }
        ticker?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        let bundle: ProjectBundle
        do {
            bundle = try await session.stop()
        } catch {
            log.error("stop failed: \(error.localizedDescription)")
            errorMessage = "Couldn't stop recording: \(error.localizedDescription)"
            phase = .idle
            elapsed = .zero
            return
        }
        phase = .exporting(0)
        do {
            let url = try await Exporter().export(bundle) { progress in
                Task { @MainActor [weak self] in
                    if case .exporting = self?.phase { self?.phase = .exporting(progress) }
                }
            }
            lastExport = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log.error("stop/export failed: \(error.localizedDescription)")
            lastExport = bundle.url
            errorMessage = "Recording saved, but export failed: \(error.localizedDescription)"
        }
        phase = .idle
        elapsed = .zero
    }

    /// Display unplugged, permission revoked, …: keep what was recorded. If an action is running, handle it right after.
    private func streamFailed(_ error: any Error) async {
        if isBusy {
            pendingFailure = error
            return
        }
        guard phase == .recording || phase == .paused else { return }
        await stop()
        // The system "Stop Sharing" button routes through here too; that's an intentional stop, not a failure.
        if let scError = error as? SCStreamError, scError.code == .userStopped { return }
        if errorMessage == nil { errorMessage = "Recording stopped: \(error.localizedDescription)" }
    }

    /// Clears the busy flag and, if a stream failure arrived while busy, handles it now instead of dropping it.
    private func finishBusy() {
        isBusy = false
        if let error = pendingFailure {
            pendingFailure = nil
            Task { await streamFailed(error) }
        }
    }

    private func startTicker() {
        let start = ContinuousClock.now - elapsed
        recordingStart = start
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = ContinuousClock.now - start
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
