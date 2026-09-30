import AppCore
import AppKit
import CaptureKit
import CoreMedia
import SwiftUI

/// What happens around the controller's commands: the target picker before a recording, the camera bubble and the
/// control bar during it, and the bubble's moves as keyframes.
@MainActor
final class RecordingCoordinator {
    private let controller: RecordingController
    private let settings: RecordingSettings
    private let session: LiveRecordingSession
    private let camera: CameraController
    private let picker = TargetPicker()
    let prompter: Prompter
    private var bubble: BubblePanel?
    private var controlBar: OverlayPanel?
    private var controlBarMoves: (any NSObjectProtocol)?
    private var panelOpen = false
    private var picking = false
    /// Whether the bubble is on screen (when the camera is on). Separate from `settings.camera`, which decides
    /// whether recordings include the camera: hiding the bubble doesn't turn the camera off for the next take.
    private var bubbleShown = false
    private var wasRecording = false

    init(controller: RecordingController, settings: RecordingSettings, session: LiveRecordingSession, camera: CameraController) {
        self.controller = controller
        self.settings = settings
        self.session = session
        self.camera = camera
        prompter = Prompter(settings: settings)
        observe()
    }

    /// The Record button and ⌥⇧R: picks the window or region if needed, then starts (the countdown runs inside the
    /// session's start). While counting down, ⌥⇧R skips the countdown instead.
    func record() async {
        if session.countdown.isRunning { return session.countdown.skip() }
        guard controller.phase == .idle, !controller.isBusy, !picking else { return }
        picking = true
        defer { picking = false }
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

    func toggleRecording() async {
        if controller.isRecording { await controller.stop() } else { await record() }
    }

    /// ⌥⇧Z: takes back the last words (to the previous pause) and keeps recording.
    func retake() async {
        guard controller.phase == .recording else { return }
        await controller.retake()
        NSSound(named: "Pop")?.play()
    }

    /// ⌥⇧M: marks this moment; markers become chapters in the export.
    func addMarker() {
        guard controller.phase == .recording, let active = session.active else { return }
        active.router.addMarker(at: CMClockGetTime(CMClockGetHostTimeClock()))
        NSSound(named: "Tink")?.play()
        AccessibilityNotification.Announcement("Marker added").post()
    }

    /// ⌥⇧D: draw on the screen (recorded) during a display or area recording.
    func toggleDrawing() {
        guard controller.isRecording else { return }
        session.drawing.toggle()
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

    func panelDidOpen() {
        panelOpen = true
        if settings.camera { bubbleShown = true }
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
            followRecordingWithPrompter()
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
        if settings.camera && bubbleShown {
            camera.start(deviceID: settings.cameraID)
            showBubble()
        } else {
            bubble?.orderOut(nil)
            bubble = nil
            // A hidden bubble still has a camera track to record: keep the camera until the recording ends.
            if !recordingActive { camera.stopSoon() }
        }
        if recordingActive && controller.phase != .starting && settings.showControls { showControlBar() } else { hideControlBar() }
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
        let host = NSHostingView(rootView: ControlBar(coordinator: self, controller: controller))
        let size = host.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
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
