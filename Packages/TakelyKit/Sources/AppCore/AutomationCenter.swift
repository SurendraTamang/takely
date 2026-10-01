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
    /// Starts without asking anything (no window or area picker): the chosen display, or `region`. Returns once
    /// recording, or once it failed or was cancelled.
    func startRecording(countdown: Bool?, region: CGRect?) async
    /// Stops and exports; returns once the export finished or failed.
    func stopRecording() async
    func togglePause() async
    /// False if no marker was added.
    func addMarker() -> Bool
    func retake() async -> Bool
    func discard() async
}

/// Runs automation commands (CLI, URL scheme, App Intents) through one path, so every entry point behaves alike
/// and gets a definite answer instead of a silent no-op.
@MainActor
public final class AutomationCenter {
    private weak var host: (any AutomationHost)?

    public init(host: any AutomationHost) {
        self.host = host
    }

    public func perform(_ request: ControlRequest) async -> ControlReply {
        guard let host else { return ControlReply(ok: false, state: "unknown", error: "Takely is quitting.") }
        switch request.command {
        case .status:
            return reply(host, path: host.lastRecording)
        case .start:
            guard host.phase == .idle, !host.isBusy else { return fail(host, isRecording(host) ? "Already recording." : "Takely is busy.") }
            await host.startRecording(countdown: request.countdown, region: request.regionRect)
            return isRecording(host) ? reply(host) : fail(host, host.errorMessage ?? "The recording didn't start.")
        case .stop:
            guard isRecording(host), !host.isBusy else { return fail(host, "Not recording.") }
            let before = host.lastRecording
            await host.stopRecording()
            guard let url = host.lastRecording, url != before || before == nil, url.pathExtension == "mp4" else {
                return fail(host, host.errorMessage ?? "The recording couldn't be exported.", path: host.lastRecording)
            }
            return reply(host, path: url)
        case .pause:
            guard host.phase == .recording else { return fail(host, "Not recording.") }
            await host.togglePause()
            return host.phase == .paused ? reply(host) : fail(host, host.errorMessage ?? "Couldn't pause.")
        case .resume:
            guard host.phase == .paused else { return fail(host, "Not paused.") }
            await host.togglePause()
            return host.phase == .recording ? reply(host) : fail(host, host.errorMessage ?? "Couldn't resume.")
        case .marker:
            guard host.phase == .recording else { return fail(host, "Not recording.") }
            return host.addMarker() ? reply(host) : fail(host, "Couldn't add a marker.")
        case .retake:
            guard host.phase == .recording else { return fail(host, "Not recording.") }
            return await host.retake() ? reply(host) : fail(host, "Nothing to take back.")
        case .discard:
            guard isRecording(host) else { return fail(host, "Not recording.") }
            await host.discard()
            return host.phase == .idle ? reply(host) : fail(host, host.errorMessage ?? "Couldn't discard.")
        }
    }

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
