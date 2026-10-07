#if canImport(TakelyPro)
    import AVFoundation
    import AppCore
    import AppKit
    import ImageIO
    import KeyboardShortcuts
    import OSLog
    import ProjectKit
    import SwiftUI
    import TakelyControl
    import TakelyPro

    extension KeyboardShortcuts.Name {
        /// Only registered while a demo runs.
        static let stopDemo = Self("stopDemo", initial: .init(.escape))
    }

    /// Demo Mode (Takely Pro): a plan (written by hand, or by the on-device model from a goal) that Takely performs
    /// on the Mac while recording it, with narration.
    @MainActor
    final class DemoMode {
        let model: DemoModel
        private var window: NSWindow?
        private var banner: OverlayPanel?
        private var runner: DemoRunner?
        /// From the first check until the demo is over (including its confirmation alerts): one demo at a time.
        private var claimed = false
        /// Stop was asked for before the steps began (e.g. while the confirmation was open).
        private var stopRequested = false
        private let center: AutomationCenter
        private let coordinator: RecordingCoordinator

        init(center: AutomationCenter, coordinator: RecordingCoordinator) {
            model = DemoModel()
            self.center = center
            self.coordinator = coordinator
            let makeRecorder = { [model] in
                let recorder = AppDemoRecorder(center: center, coordinator: coordinator)
                if model.showAvatar, model.hasAvatar { recorder.avatar = DemoModel.avatarFolder }
                return recorder
            }
            model.run = { [weak self] script, voice in
                _ = await self?.run(script, voice: voice, recorder: makeRecorder())
            }
            // `takely demo plan.txt`: the same run, with the voice and avatar chosen in the Demo Mode window.
            center.runDemo = { [weak self] text in
                guard let self else { return .failure(AutomationFailure("Takely is quitting.")) }
                let script: DemoScript
                do {
                    script = try DemoScript(parsing: text)
                } catch {
                    return .failure(AutomationFailure("The plan has an error: \(error.localizedDescription)"))
                }
                guard !script.steps.isEmpty else { return .failure(AutomationFailure("The plan has no steps.")) }
                let voice = self.model.voices.first { $0.identifier == self.model.voiceID }
                switch await self.run(script, voice: voice, recorder: makeRecorder(), fromCommandLine: true) {
                case .finished(let url): return .success(url)
                case .endedEarly:
                    return .failure(AutomationFailure("The recording stopped before the demo finished; what was recorded is saved."))
                case .failed(let message): return .failure(AutomationFailure(message))
                case nil, .idle, .running: return .failure(AutomationFailure(self.model.message ?? "The demo didn't run."))
                }
            }
            center.stopDemo = { [weak self] in
                self?.stopRequested = true
                self?.runner?.cancel()
            }
            KeyboardShortcuts.disable(.stopDemo)
            KeyboardShortcuts.onKeyUp(for: .stopDemo) { [weak self] in self?.runner?.cancel() }
        }

        func show() {
            let window =
                window
                ?? {
                    let window = NSWindow(contentViewController: NSHostingController(rootView: DemoView(model: model)))
                    window.title = "Demo Mode"
                    window.styleMask = [.titled, .closable, .resizable]
                    window.isReleasedWhenClosed = false
                    window.setContentSize(NSSize(width: 560, height: 520))
                    window.center()
                    return window
                }()
            self.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }

        /// Nil when it didn't start (one is running, no Accessibility access, or it wasn't confirmed); `model.message`
        /// then says why. A plan from the command line is always shown for a yes first: any program running as this user
        /// can send one, and it would use Takely's Accessibility access (the risky-step list can't catch everything).
        /// Those runs don't bring the window back afterwards (the command prints the outcome).
        @discardableResult
        private func run(
            _ script: DemoScript, voice: AVSpeechSynthesisVoice?, recorder: AppDemoRecorder, fromCommandLine: Bool = false
        ) async -> DemoRunner.State? {
            // Claimed before any await: a second demo can't start while this one's confirmation is open.
            guard !claimed else {
                model.message = "A demo is already running."
                return nil
            }
            claimed = true
            stopRequested = false
            center.isDemoRunning = true
            defer {
                claimed = false
                center.isDemoRunning = false
            }
            guard MacActions.isTrusted(prompt: true) else {
                model.message = DemoError.accessibilityNeeded.localizedDescription
                return nil
            }
            if fromCommandLine || !script.riskySteps.isEmpty, !(await confirm(script, fromCommandLine: fromCommandLine)) {
                model.message = "Not run: the plan wasn't confirmed."
                return nil
            }
            guard !stopRequested else {
                model.message = "Stopped before it began."
                return nil
            }
            model.running = true
            defer { model.running = false }
            let narrator = Narrator(voice: voice)
            narrator.playsAloud = model.playAloud
            defer { narrator.stopPlaying() }
            let runner = DemoRunner(script: script, actions: GuardedActions(), recorder: recorder, narrator: narrator)
            self.runner = runner
            runner.onFailure = { [weak self] index, error in await self?.askAfterFailure(index, error) ?? .stop }
            // Once the steps are over, hand the keyboard back (stopping and exporting can take a while).
            runner.onStepsDone = { [weak self] in
                KeyboardShortcuts.disable(.stopDemo)
                self?.banner?.orderOut(nil)
                self?.banner = nil
            }
            // Out of the way: the demo's clicks and keys go to the front app, which mustn't be Takely.
            window?.orderOut(nil)
            NSApp.hide(nil)
            showBanner(steps: script.steps.count)
            KeyboardShortcuts.enable(.stopDemo)
            let observer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if case .running(let step) = runner.state { self?.model.progress = "Step \(step + 1) of \(script.steps.count)" }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            let result = await runner.run()
            coordinator.avatarChoice = nil  // back to the setting for the person's own recordings
            observer.cancel()
            self.runner = nil
            switch result {
            case .finished: model.message = "Recorded and saved — see the Ready notification."
            case .endedEarly: model.message = "The recording stopped before the demo finished; what was recorded is saved."
            case .failed(let message): model.message = message
            case .idle, .running: break
            }
            if !fromCommandLine { show() }
            return result
        }

        /// Plans that can quit, delete, send, buy or open a terminal — and every plan from the command line — run only
        /// after a yes. Cancel is the default button, so a stray Return doesn't run it.
        private func confirm(_ script: DemoScript, fromCommandLine: Bool) async -> Bool {
            let alert = NSAlert()
            let risky = script.riskySteps
            if fromCommandLine {
                alert.messageText = "A command-line tool wants Takely to run this demo"
                let steps = script.text.split(separator: "\n").prefix(30).joined(separator: "\n")
                alert.informativeText =
                    "It will control your keyboard and mouse while recording. Only run it if you started it.\n\n\(steps)"
                    + (script.steps.count > 30 ? "\n…" : "")
                    + (risky.isEmpty ? "" : "\n\nSteps that may be hard to undo:\n" + risky.joined(separator: "\n"))
            } else {
                alert.messageText = "This plan has steps that may be hard to undo"
                alert.informativeText = risky.joined(separator: "\n") + "\n\nRun it anyway?"
            }
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Run")
            alert.alertStyle = .warning
            alert.window.level = .floating  // Takely may be in the background (a command-line run)
            NSApp.activate()
            return await alert.runModalFromRunLoop() == .alertSecondButtonReturn
        }

        /// A step failed: Retry, Skip or Stop. The app that was in front comes back afterwards, so a retry lands in it.
        private func askAfterFailure(_ index: Int, _ error: any Error) async -> DemoRunner.Resolution {
            let front = NSWorkspace.shared.frontmostApplication
            let alert = NSAlert()
            alert.messageText = "Step \(index + 1) didn't work"
            alert.informativeText = "\(error.localizedDescription)\n\nThe recording is still running."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Stop")
            alert.window.level = .floating
            NSApp.activate()
            let answer = await alert.runModalFromRunLoop()
            front?.activate()
            try? await Task.sleep(for: .milliseconds(400))
            switch answer {
            case .alertFirstButtonReturn: return .retry
            case .alertSecondButtonReturn: return .skip
            default: return .stop
            }
        }

        /// A small banner at the top of the screen (Takely's windows aren't recorded).
        private func showBanner(steps: Int) {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let host = NSHostingView(rootView: DemoBanner(model: model))
            let size = host.fittingSize
            let panel = OverlayPanel(
                frame: CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 8, width: size.width, height: size.height),
                activating: false, level: .statusBar)
            panel.takesKeys = false
            panel.ignoresMouseEvents = true  // a click aimed under it goes through (it's not recorded either way)
            panel.canHide = false  // stays up while Takely is hidden, without bringing its other windows back
            panel.contentView = host
            panel.orderFrontRegardless()
            banner = panel
        }
    }

    /// The real actions, with Esc (stop) switched off while the demo itself presses Esc.
    @MainActor
    private struct GuardedActions: DemoActions {
        let actions = MacActions()
        func open(app: String) async throws { try await actions.open(app: app) }
        func open(url: URL) async throws { try await actions.open(url: url) }
        func click(_ label: String) async throws { try await actions.click(label) }
        func type(_ text: String) async throws { try await actions.type(text) }
        func press(_ combo: KeyCombo) async throws {
            guard combo.key == "esc" else { return try await actions.press(combo) }
            KeyboardShortcuts.disable(.stopDemo)
            defer { KeyboardShortcuts.enable(.stopDemo) }
            try await actions.press(combo)
        }
    }

    /// Records through the automation commands (no countdown: the demo starts at once).
    @MainActor
    private final class AppDemoRecorder: DemoRecorder {
        let center: AutomationCenter
        let coordinator: RecordingCoordinator

        init(center: AutomationCenter, coordinator: RecordingCoordinator) {
            self.center = center
            self.coordinator = coordinator
        }

        struct Failed: LocalizedError {
            let errorDescription: String?
        }

        /// The avatar to put in the bubble of this recording (when there's no camera), if the person chose one.
        var avatar: URL?

        func start() async throws {
            // The demo's own avatar switch decides (the coordinator copies it in when the recording has no camera).
            coordinator.avatarChoice = avatar != nil
            let reply = await center.perform(ControlRequest(.start, countdown: false))
            guard reply.ok else { throw Failed(errorDescription: reply.error) }
        }

        func stop() async throws -> URL {
            let reply = await center.perform(ControlRequest(.stop))
            guard reply.ok, let path = reply.path else { throw Failed(errorDescription: reply.error) }
            return URL(filePath: path)
        }

        var bundle: ProjectBundle? { coordinator.controller.recordingBundle }

        var status: DemoRecordingStatus {
            switch coordinator.controller.phase {
            case .recording: .recording
            case .paused: .paused
            case .starting: .recording
            case .idle, .stopping, .exporting: .stopped
            }
        }

        func now() -> Double? {
            coordinator.session.active?.router.editedTime(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    @MainActor @Observable
    final class DemoModel {
        var goal = ""
        var plan = """
            say "Here's a quick look at TextEdit."
            open TextEdit
            key cmd+n
            wait 1
            say "Let's write a note."
            type "Recorded by Takely, hands free."
            wait 1
            say "That's it."
            """
        var message: String?
        var progress = ""
        var planning = false
        var running = false
        var voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        var voiceID: String?
        @ObservationIgnored var run: (DemoScript, AVSpeechSynthesisVoice?) async -> Void = { _, _ in }

        // MARK: Avatar

        /// Where the person's avatar is kept (only on this Mac).
        static var avatarFolder: URL { AvatarFiles.folder }
        var hasAvatar = FileManager.default.fileExists(atPath: avatarFolder.appending(path: "avatar.json").path)
        var avatarImage: NSImage? = NSImage(contentsOf: avatarFolder.appending(path: "avatar.png"))
        /// Plays the narration aloud while the demo runs (the recording has it either way).
        var playAloud = UserDefaults.standard.bool(forKey: "demoPlayAloud") {
            didSet { UserDefaults.standard.set(playAloud, forKey: "demoPlayAloud") }
        }
        var showAvatar = UserDefaults.standard.object(forKey: "demoShowAvatar") as? Bool ?? true {
            didSet { UserDefaults.standard.set(showAvatar, forKey: "demoShowAvatar") }
        }
        var avatarStyle = AvatarMaker.Style.animation
        var makingAvatar = false

        /// Only the person's own face: asked before any picture is used.
        private func confirmOwnFace() -> Bool {
            let alert = NSAlert()
            alert.messageText = "Use only a picture of yourself"
            alert.informativeText =
                "Your avatar speaks for you in recordings. Don't use anyone else's face. It's kept on this Mac and goes into the demos you record with it (and their exports)."
            alert.addButton(withTitle: "It's Me")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        private func pickImage() -> URL? {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = "Choose a portrait of yourself, facing the camera"
            return panel.runModal() == .OK ? panel.url : nil
        }

        /// From a picture of the person (`generate`: Image Playground draws a stylized portrait from it first). The
        /// work runs off the main thread; the avatar's two files are replaced together.
        func makeAvatar(generate: Bool) {
            guard let url = pickImage(), confirmOwnFace() else { return }
            makingAvatar = true
            message = generate ? "Drawing your portrait…" : "Finding your face…"
            let style = avatarStyle
            Task {
                defer { makingAvatar = false }
                do {
                    let avatar = try await Task.detached {
                        let picture = try AvatarMaker.load(url)
                        return generate ? try await AvatarMaker.generate(from: picture, style: style) : try AvatarMaker.make(from: picture)
                    }.value
                    let staging = FileManager.default.temporaryDirectory.appending(
                        path: "takely-avatar-\(UUID().uuidString)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    try avatar.png.write(to: staging.appending(path: "avatar.png"))
                    try JSONEncoder().encode(avatar.face).write(to: staging.appending(path: "avatar.json"))
                    try FileManager.default.createDirectory(
                        at: Self.avatarFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: Self.avatarFolder.path) {
                        _ = try FileManager.default.replaceItemAt(Self.avatarFolder, withItemAt: staging)
                    } else {
                        try FileManager.default.moveItem(at: staging, to: Self.avatarFolder)
                    }
                    avatarImage = NSImage(data: avatar.png)
                    hasAvatar = true
                    message = "Avatar ready: it appears in the bubble of demos recorded without the camera."
                } catch {
                    message = error.localizedDescription
                }
            }
        }

        func removeAvatar() {
            try? FileManager.default.removeItem(at: Self.avatarFolder)
            hasAvatar = false
            avatarImage = nil
            message = "Avatar removed. Demos already recorded keep theirs."
        }

        /// The plan, or why it can't run.
        var parsed: Result<DemoScript, DemoScript.ParseError> {
            do {
                return .success(try DemoScript(parsing: plan))
            } catch {
                return .failure(error)
            }
        }

        func writePlan() {
            guard DemoPlanner.isAvailable else {
                message =
                    "Writing a plan needs Apple Intelligence: turn it on in System Settings › Apple Intelligence & Siri. You can still write the plan yourself."
                return
            }
            planning = true
            message = nil
            Task {
                defer { planning = false }
                do {
                    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
                    let before = plan
                    let written = try await DemoPlanner.plan(goal: goal, apps: apps)
                    guard plan == before else {  // edited while it was being written: keep the person's text
                        message = "The plan was edited while writing; kept your version."
                        return
                    }
                    plan = written
                    message = "Check the plan before running it."
                } catch {
                    message = "Couldn't write a plan: \(error.localizedDescription)"
                }
            }
        }

        func usePersonalVoice() {
            Task {
                let personal = await Narrator.personalVoices()
                guard let first = personal.first else {
                    message =
                        "No Personal Voice available. Make one in System Settings › Accessibility › Personal Voice, and allow Takely to use it."
                    return
                }
                voices = personal + voices.filter { !personal.contains($0) }
                voiceID = first.identifier
            }
        }

        func start() {
            guard case .success(let script) = parsed, !script.steps.isEmpty else { return }
            message = nil
            let voice = voices.first { $0.identifier == voiceID }
            Task { await run(script, voice) }
        }
    }

    struct DemoView: View {
        @Bindable var model: DemoModel

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Goal, e.g. “Show how to start a new note in Notes”", text: $model.goal)
                    Button(model.planning ? "Writing…" : "Write Plan") { model.writePlan() }
                        .disabled(model.goal.isEmpty || model.planning)
                }
                Text("Plan — one step per line: open, url, click \"…\", type \"…\", key, wait, say \"…\"")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.plan)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .border(.separator)
                if case .failure(let error) = model.parsed {
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Picker("Voice", selection: $model.voiceID) {
                        Text("System default").tag(String?.none)
                        ForEach(model.voices, id: \.identifier) { voice in
                            Text(voice.voiceTraits.contains(.isPersonalVoice) ? "\(voice.name) (Personal Voice)" : voice.name)
                                .tag(Optional(voice.identifier))
                        }
                    }
                    .frame(maxWidth: 260)
                    Button("Use My Personal Voice") { model.usePersonalVoice() }
                    Spacer()
                    Button("Run & Record") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled((try? model.parsed.get())?.steps.isEmpty ?? true || model.running || model.planning)
                }
                Toggle(isOn: $model.playAloud) {
                    Text("Play the narration aloud while recording")
                    Text("Use headphones, or record without the microphone: it would hear the narration.")
                }
                avatarRow
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Text("Takely clicks and types for you while recording. Press Esc to stop; the recording so far is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    extension DemoView {
        /// The talking portrait shown in the bubble of demos recorded without the camera.
        var avatarRow: some View {
            HStack(spacing: 10) {
                if let image = model.avatarImage {
                    Image(nsImage: image).resizable().frame(width: 40, height: 40).clipShape(Circle())
                }
                Toggle("Avatar", isOn: $model.showAvatar).disabled(!model.hasAvatar)
                Spacer()
                Picker("Style", selection: $model.avatarStyle) {
                    ForEach(AvatarMaker.Style.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .frame(width: 150)
                Button("Generate from Photo…") { model.makeAvatar(generate: true) }
                    .help("Image Playground draws a stylized portrait from your photo (needs Apple Intelligence)")
                Button("Use Picture…") { model.makeAvatar(generate: false) }
                    .help("Use a portrait or drawing of yourself as it is")
                if model.hasAvatar { Button("Remove") { model.removeAvatar() } }
            }
            .disabled(model.makingAvatar || model.running)
            .controlSize(.small)
        }
    }

    private struct DemoBanner: View {
        let model: DemoModel

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text("Demo running · \(model.progress) · Esc to stop").font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
    }
#endif
