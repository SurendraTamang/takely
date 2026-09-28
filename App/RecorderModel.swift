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

    static let saveFolder = URL.moviesDirectory.appending(path: "Takely", directoryHint: .isDirectory)

    private let session = CaptureSession()
    private var clickMonitor: Any?
    private var ticker: Task<Void, Never>?
    private let log = Logger(subsystem: "app.takely", category: "app")

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            if !displays.contains(where: { $0.displayID == displayID }) {
                displayID = displays.first?.displayID
            }
            errorMessage = nil
        } catch {
            errorMessage = "Allow Screen Recording in System Settings › Privacy & Security, then reopen this menu."
        }
    }

    func start() async {
        guard phase == .idle else { return }
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
            let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
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
        do {
            switch phase {
            case .recording:
                try await session.pause()
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
            errorMessage = "Couldn't pause: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard phase == .recording || phase == .paused else { return }
        ticker?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        do {
            let bundle = try await session.stop()
            phase = .exporting(0)
            let url = try await Exporter().export(bundle) { progress in
                Task { @MainActor [weak self] in
                    if case .exporting = self?.phase { self?.phase = .exporting(progress) }
                }
            }
            lastExport = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log.error("stop/export failed: \(error.localizedDescription)")
            errorMessage = "Recording saved, but export failed: \(error.localizedDescription)"
        }
        phase = .idle
        elapsed = .zero
    }

    /// Display unplugged, permission revoked, …: keep what was recorded.
    private func streamFailed(_ error: any Error) async {
        guard phase == .recording || phase == .paused else { return }
        await stop()
        errorMessage = "Recording stopped: \(error.localizedDescription)"
    }

    private func startTicker() {
        let start = ContinuousClock.now - elapsed
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.elapsed = ContinuousClock.now - start
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
