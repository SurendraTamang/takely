#if canImport(TakelyPro)
    import AVFoundation
    import AppCore
    import AppKit
    import KeyboardShortcuts
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

        init(center: AutomationCenter, coordinator: RecordingCoordinator) {
            model = DemoModel()
            model.run = { [weak self] script, voice in
                guard let self else { return }
                await self.run(script, voice: voice, recorder: AppDemoRecorder(center: center, coordinator: coordinator))
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

        private func run(_ script: DemoScript, voice: AVSpeechSynthesisVoice?, recorder: AppDemoRecorder) async {
            guard MacActions.isTrusted(prompt: true) else {
                model.message = DemoError.accessibilityNeeded.localizedDescription
                return
            }
            let runner = DemoRunner(script: script, actions: GuardedActions(), recorder: recorder, narrator: Narrator(voice: voice))
            self.runner = runner
            runner.onFailure = { [weak self] index, error in await self?.askAfterFailure(index, error) ?? .stop }
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
            observer.cancel()
            KeyboardShortcuts.disable(.stopDemo)
            banner?.orderOut(nil)
            banner = nil
            self.runner = nil
            switch result {
            case .finished: model.message = "Recorded. The video is being finished — it appears in the Ready notification."
            case .failed(let message): model.message = message
            case .idle, .running: break
            }
            show()
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
            let answer = alert.runModal()
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
            let host = NSHostingView(rootView: DemoBanner(model: model) { [weak self] in self?.runner?.cancel() })
            let size = host.fittingSize
            let panel = OverlayPanel(
                frame: CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 8, width: size.width, height: size.height),
                activating: false, level: .statusBar)
            panel.takesKeys = false
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

        func start() async throws {
            let reply = await center.perform(ControlRequest(.start, countdown: false))
            guard reply.ok else { throw Failed(errorDescription: reply.error) }
        }

        func stop() async throws -> URL {
            let reply = await center.perform(ControlRequest(.stop))
            guard reply.ok, let path = reply.path else { throw Failed(errorDescription: reply.error) }
            return URL(filePath: path)
        }

        var bundle: ProjectBundle? { coordinator.controller.recordingBundle }

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
        var voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        var voiceID: String?
        @ObservationIgnored var run: (DemoScript, AVSpeechSynthesisVoice?) async -> Void = { _, _ in }

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
                    plan = try await DemoPlanner.plan(goal: goal, apps: apps)
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

    private struct DemoView: View {
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
                        .disabled((try? model.parsed.get())?.steps.isEmpty ?? true)
                }
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Text("Takely clicks and types for you while recording. Press Esc to stop; the recording so far is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private struct DemoBanner: View {
        let model: DemoModel
        let stop: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text("Demo running · \(model.progress) · Esc to stop").font(.callout)
                Button("Stop", action: stop).controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
    }
#endif
