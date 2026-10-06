import AppCore
import AppKit
import CaptureKit
import CoreMedia
import KeyboardShortcuts
import SwiftUI

/// What happens around the controller's commands: the target picker before a recording, the camera bubble and the
/// control bar during it, and the bubble's moves as keyframes.
@MainActor
final class RecordingCoordinator {
    let controller: RecordingController
    let settings: RecordingSettings
    let session: LiveRecordingSession
    private let camera: CameraController
    private let picker = TargetPicker()
    let prompter: Prompter
    let live = LiveFeatures()
    /// Receives the live coach's recap ("148 wpm · 4 fillers") for the take being exported (nil clears it).
    var onRecap: (String?) -> Void = { _ in }
    /// A recap computed before its export started, and the take it belongs to.
    private var pendingRecap: (take: Int, text: String?)?
    /// Counts takes, so a late recap from a discarded take can't attach to the next one.
    private var take = 0
    private var bubble: BubblePanel?
    private var controlBar: OverlayPanel?
    private var controlBarMoves: (any NSObjectProtocol)?
    private var panelOpen = false
    private var picking = false
    /// Whether the bubble is on screen (when the camera is on). Separate from `settings.camera`, which decides
    /// whether recordings include the camera: hiding the bubble doesn't turn the camera off for the next take.
    private var bubbleShown = false
    /// Whether the current recording has the camera (set as each start begins); only read while recording.
    private var recordingHasCamera = true
    private var wasRecording = false
    /// The phase the prompter and the recording-only hotkeys last followed (so a manual pause of the prompter sticks).
    private var followedPhase: RecordingController.Phase?

    init(controller: RecordingController, settings: RecordingSettings, session: LiveRecordingSession, camera: CameraController) {
        self.controller = controller
        self.settings = settings
        self.session = session
        self.camera = camera
        let live = live
        weak var prompter: Prompter?
        let made = Prompter(settings: settings, live: live.status) { on in
            Task { @MainActor in
                if on {
                    let started = await live.startPractice(
                        script: settings.prompterScript, microphoneID: settings.microphoneID, locale: settings.transcriptionLocale)
                    if started == false { prompter?.model.practicing = false }
                } else {
                    await live.stop()
                }
            }
        }
        prompter = made
        self.prompter = made
        // Set here, not when the bubble first shows: a start from the command line may come before it ever has.
        session.cameraDecided = { [weak self] uses in
            self?.recordingHasCamera = uses
            self?.update()
        }
        observe()
    }

    /// The Record button and ⌥⇧R: picks the window or region if needed, then starts (the countdown runs inside the
    /// session's start). While counting down, ⌥⇧R skips the countdown instead.
    func record() async {
        if session.countdown.isRunning { return session.countdown.skip() }
        guard controller.phase == .idle, !controller.isBusy, !picking else { return }
        picking = true
        defer { picking = false }
        session.nextStart = StartOptions()  // the person's own start: their settings, not an earlier automation's
        switch settings.target {
        case .display:
            session.target = .display
        case .window:
            guard let window = await picker.pickWindow() else { return }
            session.target = .window(window)
        case .region:
            guard let region = await picker.pickRegion(initial: settings.region) else { return }
            settings.region = region
            session.target = .region(region)
        }
        await controller.start()
    }

    /// The 3-2-1 countdown is showing (the recording hotkey then skips it).
    var isCountingDown: Bool { session.countdown.isRunning }

    func toggleRecording() async {
        if controller.isRecording { await controller.stop() } else { await record() }
    }

    /// ⌥⇧Z: takes back the last words (to the previous pause) and keeps recording.
    /// False if nothing was taken back.
    @discardableResult
    func retake() async -> Bool {
        guard controller.phase == .recording, let cut = await controller.retake() else { return false }
        live.rewind(to: cut)
        // A time-paced prompter goes back as far as the take did (one following the voice rewinds through `live`).
        prompter.model.rewind(by: CMClockGetTime(CMClockGetHostTimeClock()).seconds - cut)
        NSSound(named: "Pop")?.play()
        // The cut may have removed the bubble's latest hide or move: record where it is now.
        recordBubble(visible: settings.camera && bubbleShown)
        return true
    }

    /// ⌥⇧M: marks this moment; markers become chapters in the export.
    /// False if no marker was added.
    @discardableResult
    func addMarker() -> Bool {
        guard controller.phase == .recording, let active = session.active,
            active.router.addMarker(at: CMClockGetTime(CMClockGetHostTimeClock()))
        else { return false }
        NSSound(named: "Tink")?.play()
        AccessibilityNotification.Announcement("Marker added").post()
        return true
    }

    /// ⌥⇧D: draw on the screen (recorded) during a display or area recording.
    /// False when drawing isn't possible now (not recording, or a window recording).
    @discardableResult
    func toggleDrawing() -> Bool {
        guard controller.isRecording, session.drawing.isAvailable else { return false }
        session.drawing.toggle()
        return true
    }

    /// ⌥⇧S: shows or hides the prompter; shown mid-recording, it starts scrolling with it.
    func togglePrompter() {
        prompter.toggle()
        if prompter.isVisible, settings.prompterFollowsRecording, !prompter.model.editing {
            prompter.model.scrolling = controller.phase == .recording
        }
    }

    /// ⌥⇧C: hides the bubble, or shows it (turning the camera on if needed) so it can be placed before recording.
    func toggleBubble() {
        if settings.camera && bubbleShown {
            recordBubble(visible: false)
            bubbleShown = false
        } else {
            settings.camera = true
            bubbleShown = true
        }
        update()
    }

    func panelDidOpen(revealBubble: Bool = true) {
        panelOpen = true
        if settings.camera, revealBubble { bubbleShown = true }
        update()
    }

    func panelDidClose() {
        panelOpen = false
        update()
    }

    // MARK: State

    private func observe() {
        withObservationTracking {
            _ = (controller.phase, settings.camera, settings.cameraID, settings.showControls)
            update()
            if controller.phase != followedPhase {
                followLive(from: followedPhase, to: controller.phase)
                followedPhase = controller.phase
                followRecordingWithPrompter()
                // Retake, marker and draw only exist while recording, so their keys aren't taken from other apps.
                let names: [KeyboardShortcuts.Name] = [.retake, .addMarker, .toggleDrawing]
                if controller.isRecording { KeyboardShortcuts.enable(names) } else { KeyboardShortcuts.disable(names) }
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private var recordingActive: Bool {
        switch controller.phase {
        case .starting, .recording, .paused, .stopping: true
        case .idle, .exporting: false
        }
    }

    private func update() {
        // The bubble appears with the panel or a recording and stays until hidden (so it can be dragged into place
        // after the panel closes); a finished recording hides it unless the panel is open.
        if recordingActive != wasRecording {
            wasRecording = recordingActive
            bubbleShown = settings.camera && (recordingActive || panelOpen)
        }
        if settings.camera && bubbleShown && (recordingHasCamera || !recordingActive) {
            camera.start(deviceID: settings.cameraID)
            showBubble()
        } else {
            bubble?.orderOut(nil)
            bubble = nil
            // A hidden bubble still has a camera track to record: keep the camera until the recording ends — unless
            // this recording has no camera at all.
            if !recordingActive || !recordingHasCamera { camera.stopSoon() }
        }
        if recordingActive && controller.phase != .starting && settings.showControls { showControlBar() } else { hideControlBar() }
    }

    /// Live voice features run while recording: they start when the countdown ends and stop with the recording.
    private func followLive(from old: RecordingController.Phase?, to new: RecordingController.Phase) {
        live.status.recording = recordingActive
        let script = settings.prompterFollowsVoice && prompter.isVisible && !settings.prompterScript.isEmpty ? settings.prompterScript : nil
        if new == .starting {
            take += 1  // a new take: nothing from an earlier (e.g. discarded) one carries over
            pendingRecap = nil
            onRecap(nil)
            live.prepare(script: script, coach: settings.liveCoach, locale: settings.transcriptionLocale)
        }
        // Cancelled countdown, failed start, or a recording that ended before it was seen running.
        if old == .starting, new != .recording { live.discardPrepared() }
        if old == .starting, new == .recording, let router = session.active?.router {
            prompter.model.practicing = false
            Task {
                await live.startRecording(router: router, script: script, coach: settings.liveCoach, locale: settings.transcriptionLocale)
            }
        } else if old == .recording || old == .paused, new != .recording, new != .paused {
            let take = take
            Task {
                let recap = await live.stop()
                guard take == self.take else { return }  // a newer take started meanwhile (restart)
                // Only a take that is being exported gets a recap (not a discard).
                if case .exporting = controller.phase { onRecap(recap) } else { pendingRecap = (take, recap) }
            }
        }
        if case .exporting = new, let pending = pendingRecap, pending.take == take {
            onRecap(pending.text)
            pendingRecap = nil
        } else if new == .idle {
            pendingRecap = nil
        }
    }

    /// With "Scroll with recording", the visible prompter scrolls while recording and stops otherwise.
    private func followRecordingWithPrompter() {
        guard settings.prompterFollowsRecording, prompter.isVisible, !prompter.model.editing else { return }
        prompter.model.scrolling = controller.phase == .recording
    }

    // MARK: Bubble

    private func showBubble() {
        guard bubble == nil else { return }
        let origin = settings.bubbleOrigin.flatMap { origin in NSScreen.screens.contains { $0.frame.contains(origin) } ? origin : nil }
        let panel = BubblePanel(session: camera.session, diameter: settings.bubbleDiameter, shape: settings.bubbleShape, origin: origin)
        panel.onChange = { [weak self, weak panel] in
            guard let self, let panel else { return }
            settings.bubbleOrigin = panel.frame.origin
            settings.bubbleDiameter = panel.diameter
            settings.bubbleShape = panel.shape
            recordBubble(visible: true)
        }
        panel.onHide = { [weak self] in
            self?.recordBubble(visible: false)
            self?.bubbleShown = false
            self?.update()
        }
        panel.orderFrontRegardless()
        bubble = panel
        session.bubbleStart = { [weak self] in self?.recordBubble(visible: true) }
        recordBubble(visible: true)  // shown again mid-recording
    }

    /// Adds a keyframe for the bubble's current place (and its style) to the running recording, if any.
    private func recordBubble(visible: Bool) {
        guard let bubble, let active = session.active else { return }
        let frame = ScreenSpace.flip(bubble.frame)
        let area = active.captureRect
        // Size first (the keyframe is clamped with it), capped so it fits a small area: at most half its shorter side.
        active.router.setBubble(size: min(bubble.diameter / area.width, 0.5, 0.5 * area.height / area.width), shape: bubble.shape)
        active.router.recordBubble(
            center: CGPoint(x: frame.midX, y: frame.midY), visible: visible, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    // MARK: Control bar

    private func showControlBar() {
        guard controlBar == nil else { return }
        let host = NSHostingView(rootView: ControlBar(coordinator: self, controller: controller, live: live.status))
        let size = host.fittingSize
        // By default on the display being recorded (a saved position, wherever the person dragged it, wins).
        let recorded = session.active.map { ScreenSpace.flip($0.captureRect) }
        let screen =
            recorded.flatMap { area in NSScreen.screens.first { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) } }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let saved = settings.controlsOrigin.flatMap { origin in NSScreen.screens.contains { $0.frame.contains(origin) } ? origin : nil }
        let origin = saved ?? CGPoint(x: screen.midX - size.width / 2, y: screen.minY + 24)
        let panel = OverlayPanel(frame: CGRect(origin: origin, size: size), activating: false, level: .floating)
        panel.contentView = host
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        controlBarMoves = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self, weak panel] _ in
            MainActor.assumeIsolated { self?.settings.controlsOrigin = panel?.frame.origin }
        }
        panel.orderFrontRegardless()
        controlBar = panel
    }

    private func hideControlBar() {
        guard let controlBar else { return }
        controlBarMoves.map(NotificationCenter.default.removeObserver)
        controlBarMoves = nil
        controlBar.orderOut(nil)
        self.controlBar = nil
    }
}

/// The floating recording controls: timer · pause/resume · restart · stop · discard.
private struct ControlBar: View {
    let coordinator: RecordingCoordinator
    let controller: RecordingController
    let live: LiveStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(controller.phase == .paused ? Color.orange : .red)
                .frame(width: 8, height: 8)
                .padding(.leading, 6)
            Text(controller.elapsed.formatted(.time(pattern: .minuteSecond)))
                .font(.body.monospacedDigit())
                .frame(minWidth: 44)
                .accessibilityLabel("Elapsed time \(controller.elapsed.formatted(.units(allowed: [.minutes, .seconds])))")
            if live.coaching { coach }
            button(controller.phase == .paused ? "Resume" : "Pause", controller.phase == .paused ? "play.fill" : "pause.fill") {
                await controller.togglePause()
            }
            button("Oops, retake (⌥⇧Z)", "arrow.uturn.backward") { await coordinator.retake() }
                .disabled(controller.phase != .recording)
            button("Add marker (⌥⇧M)", "bookmark") { coordinator.addMarker() }
                .disabled(controller.phase != .recording)
            button("Restart", "arrow.counterclockwise") {
                if confirm("Discard this take and start again?", action: "Restart") { await controller.restart() }
            }
            button("Stop", "stop.fill") { await controller.stop() }
            button("Discard", "trash") {
                if confirm("Discard this recording?", action: "Discard") { await controller.discard() }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .disabled(controller.isBusy)
    }

    /// Pace (orange when slow or fast), fillers, and a nudge after a long silence.
    @ViewBuilder private var coach: some View {
        if live.isSilent && controller.phase == .recording {
            Text("Still there?").font(.caption).foregroundStyle(.secondary)
        } else if let wpm = live.wordsPerMinute {
            Text("\(wpm) wpm").font(.caption.monospacedDigit()).foregroundStyle(live.paceIsOff ? .orange : .secondary)
                .help("Speaking pace over the last 30 s (110–170 is comfortable)")
        }
        if live.fillers > 0 {
            Text("\(live.fillers) um").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Filler words so far (um, uh, you know, I mean…)")
                .accessibilityLabel("\(live.fillers) filler words")
        }
    }

    private func button(_ title: String, _ symbol: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private func confirm(_ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "It will be moved to the Trash."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
