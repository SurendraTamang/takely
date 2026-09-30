import AppCore
import CaptureKit
import ProjectKit
import SwiftUI

struct RecorderMenu: View {
    let model: RecorderModel
    let openSettings: () -> Void

    private var controller: RecordingController { model.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.phase {
            case .idle, .starting:
                setup
            case .recording, .paused, .stopping:
                controls
            case .exporting(let progress):
                ProgressView("Exporting…", value: progress)
            }
            if model.screenPermissionDenied {
                warning(
                    "Allow Screen Recording for Takely in System Settings › Privacy & Security, then quit and relaunch Takely. After a rebuild, remove the old entry first (or run `tccutil reset ScreenCapture app.takely.Takely`)."
                )
            }
            if let error = controller.errorMessage {
                warning(error)
            }
            Divider()
            HStack {
                if let url = controller.lastRecording {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",")
                if controller.phase == .idle {
                    Button("Quit") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var setup: some View {
        @Bindable var settings = model.settings
        return Group {
            Picker("Record", selection: $settings.target) {
                Text("Display").tag(CaptureTarget.display)
                Text("Window").tag(CaptureTarget.window)
                Text("Area").tag(CaptureTarget.region)
            }
            .pickerStyle(.segmented)
            if settings.target == .display {
                Picker("Display", selection: $settings.displayID) {
                    ForEach(model.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
            }
            Toggle("Camera", systemImage: "video", isOn: $settings.camera)
            if settings.camera, model.cameras.count > 1 {
                devicePicker("Camera", selection: $settings.cameraID, devices: model.cameras)
            }
            Toggle("System Audio", systemImage: "speaker.wave.2", isOn: $settings.systemAudio)
            Toggle("Microphone", systemImage: "mic", isOn: $settings.microphone)
            if settings.microphone, model.microphones.count > 1 {
                devicePicker("Microphone", selection: $settings.microphoneID, devices: model.microphones)
            }
            Picker("Quality", selection: $settings.resolution) {
                Text("720p").tag(Resolution.p720)
                Text("1080p").tag(Resolution.p1080)
                Text("Native").tag(Resolution.native)
            }
            Picker("Frame Rate", selection: $settings.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Codec", selection: $settings.codec) {
                Text("HEVC").tag(VideoCodec.hevc)
                Text("H.264").tag(VideoCodec.h264)
            }
            Button {
                Task { await model.coordinator.record() }
            } label: {
                Label(startTitle, systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.displays.isEmpty || controller.isBusy)
            Button {
                model.coordinator.togglePrompter()
            } label: {
                Label("Prompter", systemImage: "text.alignleft").frame(maxWidth: .infinity)
            }
            Text("⌥⇧R records from anywhere · ⌥⇧T opens this panel · ⌥⇧C camera · ⌥⇧S prompter")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startTitle: String {
        if controller.phase == .starting { return "Starting…" }
        switch model.settings.target {
        case .display: return "Start Recording"
        case .window: return "Choose Window…"
        case .region: return "Choose Area…"
        }
    }

    /// "System default" first, then the connected devices; a saved device that's gone shows as the default.
    private func devicePicker(_ title: String, selection: Binding<String?>, devices: [RecorderModel.Device]) -> some View {
        let shown = Binding<String?>(
            get: { selection.wrappedValue.flatMap { id in devices.contains { $0.id == id } ? id : nil } },
            set: { selection.wrappedValue = $0 })
        return Picker(title, selection: shown) {
            Text("System Default").tag(String?.none)
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Text(controller.elapsed.formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 40, weight: .light, design: .monospaced))
                .accessibilityLabel("Elapsed time \(controller.elapsed.formatted(.units(allowed: [.minutes, .seconds])))")
            HStack {
                Button {
                    Task { await controller.togglePause() }
                } label: {
                    Label(
                        controller.phase == .paused ? "Resume" : "Pause",
                        systemImage: controller.phase == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                Button {
                    Task { await controller.stop() }
                } label: {
                    Label(controller.phase == .stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(controller.isBusy)
            Text("⌥⇧Z oops, retake · ⌥⇧M marker · ⌥⇧D draw on screen")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
