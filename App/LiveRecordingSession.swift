@preconcurrency import AVFoundation
import AppCore
import AppKit
import CaptureKit
import ProjectKit
@preconcurrency import ScreenCaptureKit

enum LiveSessionError: Error, LocalizedError {
    case noDisplay, windowGone, cameraDenied, microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to record."
        case .windowGone: "That window is no longer available."
        case .cameraDenied: "Allow Camera access in System Settings, or turn the camera off."
        case .microphoneDenied: "Allow Microphone access in System Settings, or turn the microphone off."
        }
    }
}

/// The app's `RecordingSession`: ScreenCaptureKit + camera setup from the saved settings and the chosen target,
/// the countdown while the devices warm up, and the click monitor.
@MainActor
final class LiveRecordingSession: RecordingSession {
    enum Target {
        case display
        case window(SCWindow)
        /// Global points, origin top-left.
        case region(CGRect)
    }

    /// Set by the coordinator before each start; kept for a restart.
    var target = Target.display
    let countdown = Countdown()
    /// Called once the recording runs, to record the bubble's starting place.
    var bubbleStart: () -> Void = {}
    /// The running recording's router and captured area (global points), for the bubble's keyframes.
    private(set) var active: (router: FrameRouter, captureRect: CGRect)?

    private let engine = CaptureSession()
    private let settings: RecordingSettings
    private let camera: CameraController
    private var clickMonitor: Any?

    nonisolated var events: AsyncStream<CaptureEvent> { engine.events }

    init(settings: RecordingSettings, camera: CameraController) {
        self.settings = settings
        self.camera = camera
    }

    func start(in folder: URL) async throws -> RecordingHandle {
        if settings.camera, !(await AVCaptureDevice.requestAccess(for: .video)) { throw LiveSessionError.cameraDenied }
        if settings.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw LiveSessionError.microphoneDenied }
        let (filter, captureRect, sourceRect, kind) = try await capture(target)
        let scale = Double(filter.pointPixelScale)
        var config = RecordingConfig(
            target: kind, captureRect: captureRect,
            sourcePixelSize: CaptureGeometry.pixelSize(of: captureRect, scale: scale),
            resolution: settings.resolution, fps: settings.fps, codec: settings.codec,
            camera: settings.camera, systemAudio: settings.systemAudio, microphone: settings.microphone,
            echoCancellation: settings.removeEcho
        )
        config.microphoneDeviceID = settings.microphoneID
        if config.camera { camera.start(deviceID: settings.cameraID) }
        let cameraSession = camera.session
        let cameraQueue = camera.queue
        let countdown = settings.countdown ? countdown : nil
        let handle = try await engine.start(
            config: config, in: folder,
            sources: { [config] router in
                var sources: [any FrameSource] = [ScreenSource(filter: filter, config: config, sourceRect: sourceRect, router: router)]
                if config.camera { sources.append(CameraSource(router: router, session: cameraSession, queue: cameraQueue)) }
                return sources
            },
            armed: { try await countdown?.run(over: captureRect) })
        active = (handle.router, captureRect)
        bubbleStart()
        let router = handle.router
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            router.recordClick(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        return handle
    }

    /// The stream filter, the captured area (global points), the display-local source rect, and the target kind.
    private func capture(_ target: Target) async throws -> (SCContentFilter, CGRect, CGRect?, CaptureTarget) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if case .window(let window) = target {
            guard let current = content.windows.first(where: { $0.windowID == window.windowID }) else {
                throw LiveSessionError.windowGone
            }
            return (SCContentFilter(desktopIndependentWindow: current), current.frame, nil, .window)
        }
        var region: CGRect?
        if case .region(let r) = target { region = r }
        let display =
            region.flatMap { r in content.displays.first { CGDisplayBounds($0.displayID).contains(CGPoint(x: r.midX, y: r.midY)) } }
            ?? content.displays.first { $0.displayID == settings.displayID }
            ?? content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        guard let display else { throw LiveSessionError.noDisplay }
        // Exclude the app, not a window snapshot, so windows opened later (the popover) never appear.
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter =
            ownApps.isEmpty
            ? SCContentFilter(
                display: display,
                excludingWindows: content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
            : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let bounds = CGDisplayBounds(display.displayID)
        guard let region, let clamped = CaptureGeometry.clamp(region, to: bounds) else { return (filter, bounds, nil, .display) }
        return (filter, clamped, CaptureGeometry.sourceRect(for: clamped, on: bounds), .region)
    }

    func pause() async throws { try await engine.pause() }
    func resume() async throws { try await engine.resume() }

    func stop() async throws -> StoppedRecording {
        removeClickMonitor()
        active = nil
        return try await engine.stop()
    }

    func state() async -> CaptureSession.State {
        let state = await engine.state
        if state == .idle {
            removeClickMonitor()
            active = nil
        }
        return state
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
