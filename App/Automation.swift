import AppCore
import AppIntents
import AppKit
import OSLog
import TakelyControl

/// Automation drives the same controls as the panel and hotkeys, without asking anything: the chosen display, or
/// the area it's given (no window or area picker).
extension RecordingCoordinator: AutomationHost {
    var phase: RecordingController.Phase { controller.phase }
    var isBusy: Bool { controller.isBusy }
    var errorMessage: String? { controller.errorMessage }
    var lastRecording: URL? { controller.lastRecording }

    func startRecording(countdown: Bool?, region: CGRect?) async {
        session.target = region.map { .region($0) } ?? .display
        session.countdownOverride = countdown
        await controller.start()
        session.countdownOverride = nil  // also when the start failed before reading it
    }

    func stopRecording() async { await controller.stop() }
    func togglePause() async { await controller.togglePause() }
    func discard() async { await controller.discard() }
}

/// The automation entry points: the `takely` CLI's socket, the `takely://` URL scheme (x-callback-url) and App
/// Intents (Shortcuts, Siri, Spotlight) all go through one `AutomationCenter`.
@MainActor
final class Automation {
    let center: AutomationCenter
    private var server: SocketServer?

    init(host: any AutomationHost) {
        center = AutomationCenter(host: host)
        let center = center
        AppDependencyManager.shared.add(dependency: center)
        server = SocketServer { request in await center.perform(request) }
        do {
            try server?.start()
        } catch {
            Logger.automation.error("control socket unavailable: \(error.localizedDescription)")
            server = nil
        }
    }

    func stop() { server?.stop() }

    /// `takely://record/start?…`: runs the command, then opens the x-success or x-error callback, if any.
    func open(_ url: URL) {
        guard let command = ControlURL(url) else { return Logger.automation.error("unknown URL \(url.absoluteString)") }
        Task {
            let reply = await center.perform(command.request)
            if let callback = command.callback(for: reply) { NSWorkspace.shared.open(callback) }
        }
    }
}

extension Logger {
    static let automation = Logger(subsystem: "app.takely", category: "automation")
}

// MARK: App Intents

/// The reason a command failed, shown by Shortcuts or Siri.
struct AutomationError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private func run(_ request: ControlRequest, with center: AutomationCenter) async throws -> ControlReply {
    let reply = await center.perform(request)
    guard reply.ok else { throw AutomationError(message: reply.error ?? "Failed.") }
    return reply
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts recording the screen chosen in Takely.")
    @Parameter(title: "Countdown", default: true) var countdown: Bool
    @Dependency var center: AutomationCenter

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(ControlRequest(.start, countdown: countdown), with: center)
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops recording and returns the exported video.")
    @Dependency var center: AutomationCenter

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let reply = try await run(ControlRequest(.stop), with: center)
        guard let path = reply.path else { throw AutomationError(message: "No video was exported.") }
        return .result(value: IntentFile(fileURL: URL(filePath: path)))
    }
}

struct PauseRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Recording"
    @Dependency var center: AutomationCenter

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(ControlRequest(.pause), with: center)
        return .result()
    }
}

struct ResumeRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    @Dependency var center: AutomationCenter

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(ControlRequest(.resume), with: center)
        return .result()
    }
}

struct AddMarkerIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Marker"
    static let description = IntentDescription("Marks this moment of the recording; markers become chapters.")
    @Dependency var center: AutomationCenter

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(ControlRequest(.marker), with: center)
        return .result()
    }
}

struct RecordingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recording Status"
    @Dependency var center: AutomationCenter

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await run(ControlRequest(.status), with: center).state)
    }
}

struct TakelyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start a \(.applicationName) recording", "Record my screen with \(.applicationName)"],
            shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(
            intent: StopRecordingIntent(), phrases: ["Stop the \(.applicationName) recording"], shortTitle: "Stop Recording",
            systemImageName: "stop.circle")
        AppShortcut(
            intent: AddMarkerIntent(), phrases: ["Add a \(.applicationName) marker"], shortTitle: "Add Marker", systemImageName: "bookmark")
    }
}
