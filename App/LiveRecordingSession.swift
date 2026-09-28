import AVFoundation
import AppCore
import AppKit
import CaptureKit
import ProjectKit
@preconcurrency import ScreenCaptureKit

enum LiveSessionError: Error, LocalizedError {
    case noDisplay, cameraDenied, microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to record."
        case .cameraDenied: "Allow Camera access in System Settings, or turn the camera off."
        case .microphoneDenied: "Allow Microphone access in System Settings, or turn the microphone off."
        }
    }
}

/// The app's `RecordingSession`: ScreenCaptureKit + camera setup from the saved settings, and the click monitor.
@MainActor
final class LiveRecordingSession: RecordingSession {
    private let engine = CaptureSession()
    private let settings: RecordingSettings
    private var clickMonitor: Any?

    nonisolated var events: AsyncStream<CaptureEvent> { engine.events }

    init(settings: RecordingSettings) {
        self.settings = settings
    }

    func start(in folder: URL) async throws -> RecordingHandle {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == settings.displayID }) ?? content.displays.first else {
            throw LiveSessionError.noDisplay
        }
        if settings.camera, !(await AVCaptureDevice.requestAccess(for: .video)) { throw LiveSessionError.cameraDenied }
        if settings.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw LiveSessionError.microphoneDenied }
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
            resolution: settings.resolution, fps: settings.fps, codec: settings.codec,
            camera: settings.camera, systemAudio: settings.systemAudio, microphone: settings.microphone
        )
        let handle = try await engine.start(config: config, in: folder) { router in
            var sources: [any FrameSource] = [ScreenSource(filter: filter, config: config, sourceRect: nil, router: router)]
            if config.camera { sources.append(try CameraSource(router: router)) }
            return sources
        }
        let router = handle.router
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            router.recordClick(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        return handle
    }

    func pause() async throws { try await engine.pause() }
    func resume() async throws { try await engine.resume() }

    func stop() async throws -> ProjectBundle {
        removeClickMonitor()
        return try await engine.stop()
    }

    func state() async -> CaptureSession.State {
        let state = await engine.state
        if state == .idle { removeClickMonitor() }
        return state
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
