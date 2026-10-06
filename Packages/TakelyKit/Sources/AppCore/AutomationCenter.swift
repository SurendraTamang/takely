import Foundation
import ProjectKit
import TakelyControl

/// What automation drives: the app's recording controls (the coordinator in the app; a fake in tests).
@MainActor
public protocol AutomationHost: AnyObject {
    var phase: RecordingController.Phase { get }
    var isBusy: Bool { get }
    var errorMessage: String? { get }
    var lastRecording: URL? { get }
    /// Starts without asking anything (no window or area picker): the chosen display, or what `options` says.
    /// Returns once recording, or once it failed or was cancelled.
    func startRecording(_ options: StartOptions) async
    /// Stops and exports; returns once the export finished or failed.
    func stopRecording() async
    func togglePause() async
    /// False if no marker was added.
    func addMarker() -> Bool
    func retake() async -> Bool
    func discard() async
}

/// How an automation start differs from the user's settings, for that recording only.
public struct StartOptions: Sendable, Equatable {
    /// False skips the 3-2-1 countdown.
    public var countdown: Bool?
    /// An area (global points) instead of a display.
    public var region: CGRect?
    /// False records without the camera / the microphone.
    public var camera: Bool?
    public var microphone: Bool?
    /// The display to record, counted from 1 left to right.
    public var display: Int?
    /// A window to record, by app or title (see `WindowMatch`).
    public var window: String?

    public init(
        countdown: Bool? = nil, region: CGRect? = nil, camera: Bool? = nil, microphone: Bool? = nil, display: Int? = nil,
        window: String? = nil
    ) {
        self.window = window
        self.countdown = countdown
        self.region = region
        self.camera = camera
        self.microphone = microphone
        self.display = display
    }
}

/// Why an automation command failed, in words for the person who ran it.
public struct AutomationFailure: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Runs automation commands (CLI, URL scheme, App Intents) through one path, so every entry point behaves alike
/// and gets a definite answer instead of a silent no-op.
@MainActor
public final class AutomationCenter {
    private weak var host: (any AutomationHost)?
    /// Runs a Demo Mode plan and returns the finished video, or why it didn't run (set by Takely Pro).
    public var runDemo: ((String) async -> Result<URL, AutomationFailure>)?
    /// A demo is running (or being confirmed): it presses keys, so a link's confirmation alert could be answered by
    /// the demo itself — links are refused meanwhile.
    public var isDemoRunning = false
    /// Stops the running demo (set by Takely Pro).
    public var stopDemo: (() -> Void)?

    public init(host: any AutomationHost) {
        self.host = host
    }

    public func perform(_ request: ControlRequest) async -> ControlReply {
        guard let host else { return ControlReply(ok: false, state: "unknown", error: "Takely is quitting.") }
        switch request.command {
        case .status:
            return reply(host, path: host.lastRecording)
        case .start:
            guard !request.hasInvalidRegion else { return fail(host, "The region needs x, y, width and height, with a positive size.") }
            if let display = request.display, display < 1 { return fail(host, "Displays are counted from 1 (left to right).") }
            guard [request.display != nil, request.region != nil, request.window != nil].filter({ $0 }).count <= 1 else {
                return fail(host, "Give one of a display, a region or a window.")
            }
            guard host.phase == .idle, !host.isBusy else { return fail(host, isRecording(host) ? "Already recording." : "Takely is busy.") }
            await host.startRecording(
                StartOptions(
                    countdown: request.countdown, region: request.regionRect, camera: request.camera, microphone: request.microphone,
                    display: request.display, window: request.window))
            return isRecording(host) ? reply(host) : fail(host, host.errorMessage ?? "The recording didn't start.")
        case .stop:
            if let refusal = stopRefusal(host) { return refusal }
            let before = host.lastRecording
            await host.stopRecording()
            let after = host.lastRecording == before ? nil : host.lastRecording  // a failed stop leaves the last take's
            guard let url = after, url.pathExtension == "mp4" else {
                return fail(host, host.errorMessage ?? "The recording couldn't be exported.", path: after)
            }
            return reply(host, path: url)
        case .pause:
            guard host.phase == .recording, !host.isBusy else {
                return fail(host, host.phase == .paused ? "Already paused." : "Not recording.")
            }
            await host.togglePause()
            return host.phase == .paused ? reply(host) : fail(host, host.errorMessage ?? "Couldn't pause.")
        case .resume:
            guard host.phase == .paused, !host.isBusy else { return fail(host, "Not paused.") }
            await host.togglePause()
            return host.phase == .recording ? reply(host) : fail(host, host.errorMessage ?? "Couldn't resume.")
        case .marker:
            guard host.phase == .recording else { return fail(host, host.phase == .paused ? "Paused: resume first." : "Not recording.") }
            return host.addMarker() ? reply(host) : fail(host, "Couldn't add a marker.")
        case .retake:
            guard host.phase == .recording, !host.isBusy else {
                return fail(host, host.phase == .paused ? "Paused: resume first." : "Not recording.")
            }
            if await host.retake() { return reply(host) }
            return fail(host, host.phase == .recording ? "Nothing to take back." : host.errorMessage ?? "The retake failed.")
        case .demo:
            guard let runDemo else { return fail(host, "Demo Mode is part of Takely Pro.") }
            guard let plan = request.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail(host, "The plan is empty.")
            }
            guard host.phase == .idle, !host.isBusy else { return fail(host, isRecording(host) ? "Already recording." : "Takely is busy.") }
            switch await runDemo(plan) {
            case .success(let url): return reply(host, path: url)
            case .failure(let failure): return fail(host, failure.message)
            }
        case .stopDemo:
            guard isDemoRunning, let stopDemo else { return fail(host, "No demo is running.") }
            stopDemo()
            return reply(host)
        case .discard:
            if host.phase == .starting { return fail(host, Self.starting) }
            guard isRecording(host), !host.isBusy else { return fail(host, "Not recording.") }
            await host.discard()
            return host.phase == .idle && host.errorMessage == nil ? reply(host) : fail(host, host.errorMessage ?? "Couldn't discard.")
        }
    }

    /// Starts stopping and answers at once (the export runs on; the Ready notification follows): checked like `stop`,
    /// so a refusal (busy pausing or retaking, not recording) is reported, not lost.
    public func stopWithoutWaiting() -> ControlReply {
        guard let host else { return ControlReply(ok: false, state: "unknown", error: "Takely is quitting.") }
        if let refusal = stopRefusal(host) { return refusal }
        Task { await host.stopRecording() }
        return reply(host)
    }

    private func stopRefusal(_ host: any AutomationHost) -> ControlReply? {
        if host.phase == .starting { return fail(host, Self.starting) }
        if host.isBusy && isRecording(host) { return fail(host, "Takely is busy (pausing or retaking): try again in a moment.") }
        guard isRecording(host), !host.isBusy else { return fail(host, "Not recording.") }
        return nil
    }

    /// During the countdown (or while devices start) the recording can't be stopped yet; Esc cancels it.
    static let starting = "Still starting: wait for the countdown to end (Esc cancels it)."

    public static func state(_ phase: RecordingController.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .paused: "paused"
        case .stopping: "stopping"
        case .exporting: "exporting"
        }
    }

    private func isRecording(_ host: any AutomationHost) -> Bool {
        host.phase == .recording || host.phase == .paused || host.phase == .starting
    }

    /// Success, with the video's length (as exported, after edits) and title when there's one.
    private func reply(_ host: any AutomationHost, path: URL? = nil) -> ControlReply {
        var reply = ControlReply(ok: true, state: Self.state(host.phase), path: path?.path)
        if let path, let bundle = ProjectBundle.containing(path), let project = try? bundle.readProject() {
            let cuts = (try? bundle.readEdits())?.cuts ?? []
            reply.duration = EditMap(cuts: cuts, duration: project.duration).outputDuration
            reply.title = project.title
        }
        return reply
    }

    private func fail(_ host: any AutomationHost, _ message: String, path: URL? = nil) -> ControlReply {
        ControlReply(ok: false, state: Self.state(host.phase), path: path?.path, error: message)
    }
}
