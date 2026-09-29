import AppCore
import AppKit
import OSLog
import ProjectKit
import RenderKit
import SwiftUI

/// Owns the app's objects and handles launch (recovery) and quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = RecordingSettings()
    private let notifier = ReadyNotifier()
    private(set) lazy var controller = RecordingController(
        session: LiveRecordingSession(settings: settings),
        exporter: Exporter(),
        feedback: notifier,
        saveFolder: { [settings] in settings.saveFolder })
    private lazy var model = RecorderModel(controller: controller, settings: settings)
    private var statusItem: StatusItemController?
    /// When macOS last announced a power-off, as a backup to the quit event's reason.
    /// Trusted only briefly: another app can cancel the restart, and later quits are the user's.
    private var powerOffNoticedAt: ContinuousClock.Instant?
    /// True while a quit waits for the recording to stop (and, for a user quit, export).
    private var quitInProgress = false
    private let log = Logger(subsystem: "app.takely", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.activate()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        HotkeyCenter.install(controller: controller, statusItem: statusItem)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerOffNoticedAt = .now }
        }
        Task { await offerRecovery() }
    }

    // MARK: Quit

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitInProgress { return .terminateCancel }  // a repeated ⌘Q; the pending quit finishes on its own
        guard controller.phase != .idle || controller.isBusy else { return .terminateNow }
        let system = isSystemQuit()
        if !system && (controller.isRecording || controller.phase == .starting) {
            let alert = NSAlert()
            alert.messageText = "Stop recording and quit?"
            alert.informativeText = "Takely will save and export your recording before quitting."
            alert.addButton(withTitle: "Stop & Save")
            alert.addButton(withTitle: "Keep Recording")
            alert.window.level = .floating  // a menu bar app's activation can be refused
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        quitInProgress = true
        if !system { statusItem?.showPanel() }  // shows the export progress while the quit waits for it
        Task {
            await controller.stopForQuit(system: system)
            replyToQuit(sender)
        }
        if system {
            // macOS won't wait long on logout/restart: reply anyway after 5 s; recovery handles whatever is left.
            Task {
                try? await Task.sleep(for: .seconds(5))
                replyToQuit(sender)
            }
        }
        return .terminateLater
    }

    private func replyToQuit(_ sender: NSApplication) {
        guard quitInProgress else { return }
        quitInProgress = false
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// Logout, restart and shutdown send a quit event with a reason; a user ⌘Q has none.
    private func isSystemQuit() -> Bool {
        if let noticed = powerOffNoticedAt, ContinuousClock.now - noticed < .seconds(60) { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let systemReasons: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAERestart),
            OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
        ]
        return systemReasons.contains(reason)
    }

    // MARK: Recovery

    private func offerRecovery() async {
        for candidate in RecoveryService.scan(settings.saveFolder) {
            let when = candidate.createdAt.formatted(date: .abbreviated, time: .shortened)
            if candidate.kind == .empty {
                let answer = ask(
                    "Takely found an empty recording", "From \(when). It has no video, so it can only be moved to the Trash.",
                    buttons: ["Delete", "Later"])
                if answer == .alertFirstButtonReturn { await moveToTrash(candidate.bundle) }
                continue
            }
            let answer = ask(
                "Takely found a recording that wasn't saved",
                "From \(when). Recover it to finish saving and export it, or move it to the Trash.",
                buttons: ["Recover", "Delete", "Later"])
            switch answer {
            case .alertFirstButtonReturn:
                do {
                    if candidate.kind == .crashed {
                        let report = try await RecoveryService.rebuild(candidate.bundle)
                        if !report.skipped.isEmpty { log.info("recovery skipped \(report.skipped)") }
                    }
                    await controller.waitUntilIdle()
                    // A hotkey may have started a recording while the alert was open: keep the bundle for next launch.
                    guard controller.phase == .idle else {
                        log.info("recovery export deferred: a recording is in progress")
                        continue
                    }
                    await controller.export(candidate.bundle)
                } catch {
                    // Nothing usable: offer the Trash so it isn't offered again on every launch.
                    let retry = ask("Couldn't recover this recording", error.localizedDescription, buttons: ["Delete", "Keep"])
                    if retry == .alertFirstButtonReturn { await moveToTrash(candidate.bundle) }
                }
            case .alertSecondButtonReturn:
                await moveToTrash(candidate.bundle)
            default:
                break  // Later: ask again next launch
            }
        }
    }

    private func ask(_ title: String, _ message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.window.level = .floating  // stays visible when launched at login, before the app is active
        NSApp.activate()
        return alert.runModal()
    }

    private func moveToTrash(_ bundle: ProjectBundle) async {
        do {
            try await NSWorkspace.shared.recycle([bundle.url])
        } catch {
            log.error("moving \(bundle.url.lastPathComponent) to Trash failed: \(error.localizedDescription)")
        }
    }
}
