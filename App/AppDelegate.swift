import AppCore
import AppIntents
import AppKit
import OSLog
import ProjectKit
import RenderKit
import SwiftUI

#if canImport(TakelyPro)
    import TakelyPro
#endif

/// Owns the app's objects and handles launch (recovery, onboarding) and quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = RecordingSettings()
    let permissions = Permissions()
    private let notifier = ReadyNotifier()
    private lazy var sharing = Sharing(settings: settings, notifier: notifier)
    private let camera = CameraController()
    private lazy var session = LiveRecordingSession(settings: settings, camera: camera)
    private(set) lazy var controller = RecordingController(
        session: session,
        exporter: Exporter(),
        postProcessor: Self.postProcessor(settings: settings),
        feedback: notifier,
        saveFolder: { [settings] in settings.saveFolder })
    /// Takely Pro's transcript and AI pass when it's part of the build; the open-source build has none.
    private static func postProcessor(settings: RecordingSettings) -> (any PostProcessor)? {
        #if canImport(TakelyPro)
            ProProcessor { [settings] in
                await MainActor.run {
                    ProProcessor.Options(
                        transcribe: settings.transcribe, locale: settings.transcriptionLocale, summarize: settings.aiSummary,
                        burnInCaptions: settings.burnInCaptions, redact: settings.redactSecrets,
                        autoZoom: settings.autoZoom, removeSilences: settings.removeSilences)
                }
            }
        #else
            nil
        #endif
    }

    private lazy var coordinator = RecordingCoordinator(controller: controller, settings: settings, session: session, camera: camera)
    private lazy var model = RecorderModel(controller: controller, settings: settings, coordinator: coordinator)
    private var statusItem: StatusItemController?
    private var automation: Automation?
    private let updates = Updates()
    #if canImport(TakelyPro)
        /// Takely Pro's trial or license; re-checked at launch and daily.
        private let license = LicenseManager()
    #endif
    private var meetings: MeetingMonitor?
    #if canImport(TakelyPro)
        private var demo: DemoMode?
    #endif
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var reviewWindow: NSWindow?
    private var editorWindow: NSWindow?
    #if canImport(TakelyPro)
        private var editor: EditorModel?
    #endif
    /// When macOS last announced a power-off, as a backup to the quit event's reason.
    /// Trusted only briefly: another app can cancel the restart, and later quits are the user's.
    private var powerOffNoticedAt: ContinuousClock.Instant?
    /// True while a quit waits for the recording to stop (and, for a user quit, export).
    private var quitInProgress = false
    private let log = Logger(subsystem: "app.takely", category: "app")

    /// App Intents can run as soon as the app launches (Shortcuts or Siri launch it): their dependency waits until
    /// automation is ready.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One Takely at a time: a second copy would offer to "recover" the first one's live recording and fight
        // it for the hotkeys and the automation socket.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter { other in
            guard other.processIdentifier != getpid(), !other.isTerminated else { return false }
            #if DEBUG
                if other.bundleURL != Bundle.main.bundleURL { return false }  // a development build beside the installed app
            #endif
            // Two launched at once (login item and a click): the older one stays.
            let theirs = other.launchDate ?? .distantPast
            let mine = me.launchDate ?? .distantFuture
            return theirs < mine || (theirs == mine && other.processIdentifier < getpid())
        }
        if let other = others.first {
            let alert = NSAlert()
            alert.messageText = "Takely is already running"
            alert.informativeText =
                "Use the Takely icon in the menu bar\(other.bundleURL.map { " (\($0.path(percentEncoded: false)))" } ?? "")."
            NSApp.activate()
            alert.runModal()
            exit(0)  // before anything starts: nothing to save
        }
        AppDependencyManager.shared.add { @MainActor [weak self] () async -> AutomationCenter in
            while true {
                if let center = self?.automation?.center { return center }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if canImport(TakelyPro)
            let openEditor: ((ProjectBundle) -> Void)? = { [weak self] bundle in
                guard let self, ProUnlock.allowed(license, openSettings: showSettings) else { return }
                showEditor(bundle)
            }
            let openDemo: (() -> Void)? = { [weak self] in
                guard let self, ProUnlock.allowed(license, openSettings: showSettings) else { return }
                self.statusItem?.closePanel()
                self.demo?.show()
            }
        #else
            let openEditor: ((ProjectBundle) -> Void)? = nil
            let openDemo: (() -> Void)? = nil
        #endif
        notifier.onEdit = openEditor
        notifier.onShare = { [weak self] bundle in
            guard let self else { return }
            if sharing.isConfigured { sharing.share(bundle) } else { showSettings() }
        }
        notifier.onExported = { [weak self] url in self?.sharing.recordingExported(url) }
        // Not while quitting or logging out: then there's nobody to show it to, and nothing to bring forward.
        notifier.onUnseenFailure = { [weak self] in
            guard let self, !quitInProgress, powerOffNoticedAt == nil else { return }
            self.statusItem?.showPanel(revealBubble: false)
        }
        notifier.onRetryExport = { [weak self] bundle in
            guard let self else { return }
            Task { await self.controller.export(bundle) }
        }
        notifier.activate()
        let statusItem = StatusItemController(
            model: model, openSettings: { [weak self] in self?.showSettings() }, openEditor: openEditor, openDemo: openDemo,
            sharing: sharing, checkForUpdates: updates.isAvailable ? { [updates] in updates.check() } : nil)
        self.statusItem = statusItem
        HotkeyCenter.install(controller: controller, coordinator: coordinator, statusItem: statusItem)
        automation = Automation(host: coordinator, settings: settings)
        #if canImport(TakelyPro)
            // Hourly: the trial's end and the offline grace take effect on time (the key itself is checked weekly).
            Task { [license] in
                while !Task.isCancelled {
                    await license.refresh()
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [license] _ in Task { @MainActor in await license.refresh() }
            }
        #endif
        meetings = MeetingMonitor(settings: settings, controller: controller, session: session, notifier: notifier)
        meetings?.start()
        #if canImport(TakelyPro)
            if let center = automation?.center { demo = DemoMode(center: center, coordinator: coordinator) }
        #endif
        coordinator.onRecap = { [notifier] recap in notifier.recap = recap }
        notifier.onReview = { [weak self] bundle in self?.showReview(bundle) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerOffNoticedAt = .now }
        }
        Task {
            await offerRecovery()
            if !settings.hasOnboarded { showOnboarding() }  // after recovery, so its alerts don't stack on the welcome
        }
    }

    /// `takely://…` (the URL scheme for automation). URLs that arrive while launching wait for the app to be ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task {
            while automation == nil { try? await Task.sleep(for: .milliseconds(50)) }
            urls.forEach { automation?.open($0) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        automation?.stop()
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
        // Off the main thread: an old folder on a sleeping disk or a stale network share mustn't hang the launch.
        let folders = [settings.saveFolder] + settings.pastSaveFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let candidates = await Task.detached {
            var seen = Set<String>()
            return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
                .flatMap { RecoveryService.scan($0) }
                .filter { seen.insert($0.bundle.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        }.value
        for candidate in candidates {
            let when = candidate.createdAt.formatted(date: .abbreviated, time: .shortened)
            if candidate.kind == .empty {
                let answer = await ask(
                    "Takely found an empty recording", "From \(when). It has no video, so it can only be moved to the Trash.",
                    buttons: ["Delete", "Later"])
                if answer == .alertFirstButtonReturn { await moveToTrash(candidate.bundle) }
                continue
            }
            let answer = await ask(
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
                        await notifier.recordingFailed(
                            "The recovered recording from \(when) wasn't exported: another recording started. It's offered again next launch."
                        )
                        continue
                    }
                    await controller.export(candidate.bundle)
                } catch {
                    // Nothing usable: offer the Trash so it isn't offered again on every launch.
                    let retry = await ask("Couldn't recover this recording", error.localizedDescription, buttons: ["Delete", "Keep"])
                    if retry == .alertFirstButtonReturn { await moveToTrash(candidate.bundle) }
                }
            case .alertSecondButtonReturn:
                await moveToTrash(candidate.bundle)
            default:
                break  // Later: ask again next launch
            }
        }
    }

    private func ask(_ title: String, _ message: String, buttons: [String]) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.window.level = .floating  // stays visible when launched at login, before the app is active
        NSApp.activate()
        return await alert.runModalFromRunLoop()
    }

    private func moveToTrash(_ bundle: ProjectBundle) async {
        do {
            try await NSWorkspace.shared.recycle([bundle.url])
        } catch {
            log.error("moving \(bundle.url.lastPathComponent) to Trash failed: \(error.localizedDescription)")
        }
    }

    // MARK: Windows

    private var licenseView: AnyView? {
        #if canImport(TakelyPro)
            AnyView(LicenseView(license: license))
        #else
            nil
        #endif
    }

    func showSettings() {
        statusItem?.closePanel()
        let window =
            settingsWindow
            ?? makeWindow(
                title: "Takely Settings",
                content: SettingsView(
                    settings: settings, permissions: permissions, showOnboarding: { [weak self] in self?.showOnboarding() },
                    sharing: sharing, license: licenseView))
        settingsWindow = window
        present(window)
    }

    func showOnboarding() {
        let window =
            onboardingWindow
            ?? makeWindow(
                title: "Welcome to Takely",
                content: OnboardingView(permissions: permissions) { [weak self] in self?.onboardingWindow?.close() })
        onboardingWindow = window
        present(window)
    }

    /// The blurred areas of a recording, to switch off, add to and re-export.
    func showReview(_ bundle: ProjectBundle) {
        reviewWindow?.close()
        let model = BlurReviewModel(bundle: bundle)
        let window = makeWindow(
            title: "Blurred Areas — \(bundle.name)",
            content: BlurReviewView(model: model) { [weak self] in
                guard let self else { return nil }
                guard controller.phase == .idle, !controller.isBusy else { return "Finish the current recording or export first." }
                reviewWindow?.close()
                statusItem?.showPanel()  // shows the export's progress
                Task { await self.controller.export(bundle) }
                return nil
            })
        reviewWindow = window
        present(window)
    }

    #if canImport(TakelyPro)
        /// The editor on a recording (one at a time).
        func showEditor(_ bundle: ProjectBundle) {
            statusItem?.closePanel()
            if editor?.session.bundle.url == bundle.url, let editorWindow { return present(editorWindow) }
            editorWindow?.close()
            do {
                let model = try EditorModel(session: EditSession(bundle: bundle))
                let window = makeWindow(
                    title: "Edit — \(bundle.name)",
                    content: EditorView(model: model) { [weak self] in
                        guard let self else { return nil }
                        guard controller.phase == .idle, !controller.isBusy else { return "Finish the current recording or export first." }
                        do {
                            try model.session.save()
                        } catch {
                            return "Couldn't save the edits: \(error.localizedDescription)"
                        }
                        editorWindow?.close()
                        statusItem?.showPanel()  // shows the export's progress
                        Task { await self.controller.export(bundle) }
                        return nil
                    })
                window.styleMask.insert([.resizable, .miniaturizable])
                window.setContentSize(NSSize(width: 1000, height: 680))
                window.center()
                editor = model
                editorWindow = window
                present(window)
            } catch {
                Task { _ = await ask("Couldn't open this recording", error.localizedDescription, buttons: ["OK"]) }
            }
        }
    #endif

    private func makeWindow(title: String, content: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Menu-bar apps must activate themselves, or the window opens behind other apps.
    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Drops closed windows so their polling stops and the next open shows fresh state.
    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === onboardingWindow {
            settings.hasOnboarded = true  // closing the welcome counts as Done
            onboardingWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        } else if window === reviewWindow {
            reviewWindow = nil
        } else if window === editorWindow {
            #if canImport(TakelyPro)
                // Edits are kept (they're non-destructive): the next export of this recording uses them.
                if let session = editor?.session, session.changed {
                    do {
                        try session.save()
                    } catch {
                        log.error("saving edits failed: \(error.localizedDescription)")
                    }
                }
                editor?.close()
                editor = nil
            #endif
            editorWindow = nil
        }
    }
}

extension NSAlert {
    /// `runModal()` from a main-actor task: the task runs inside a main-queue job, which the alert's run loop can't
    /// re-enter, so every other main-actor task (hotkey actions, the menu bar timer, recording updates) waits until
    /// the alert is answered. Started from the run loop instead, they keep running.
    func runModalFromRunLoop() async -> NSApplication.ModalResponse {
        nonisolated(unsafe) let alert = self
        return await withCheckedContinuation { continuation in
            RunLoop.main.perform { MainActor.assumeIsolated { continuation.resume(returning: alert.runModal()) } }
        }
    }
}
