import AppKit
import CaptureKit
import KeyboardShortcuts
import ProjectKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: RecordingSettings
    let permissions: Permissions
    let showOnboarding: () -> Void

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Recording", systemImage: "record.circle") { recording }
            Tab("Shortcuts", systemImage: "keyboard") { shortcuts }
            Tab("Permissions", systemImage: "lock.shield") { permissionsTab }
        }
        .frame(width: 480, height: 320)
    }

    private var general: some View {
        Form {
            LabeledContent("Save recordings to") {
                HStack {
                    Text(settings.saveFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            LaunchAtLoginToggle()
        }
        .padding()
    }

    private var recording: some View {
        Form {
            Toggle("Camera", isOn: $settings.camera)
            Toggle("System audio", isOn: $settings.systemAudio)
            Toggle("Microphone", isOn: $settings.microphone)
            Picker("Quality", selection: $settings.resolution) {
                Text("720p").tag(Resolution.p720)
                Text("1080p").tag(Resolution.p1080)
                Text("Native").tag(Resolution.native)
            }
            Picker("Frame rate", selection: $settings.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Codec", selection: $settings.codec) {
                Text("HEVC").tag(VideoCodec.hevc)
                Text("H.264").tag(VideoCodec.h264)
            }
        }
        .padding()
    }

    private var shortcuts: some View {
        Form {
            KeyboardShortcuts.Recorder("Start / stop recording:", name: .toggleRecording)
            KeyboardShortcuts.Recorder("Pause / resume:", name: .togglePause)
            KeyboardShortcuts.Recorder("Show Takely panel:", name: .togglePanel)
            Text("On some keyboard layouts ⌥⇧ + a letter types a special character; pick another shortcut if you need it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionRows(permissions: permissions)
            Spacer()
            Button("Show Welcome Again", action: showOnboarding)
        }
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolder = url }
    }
}

/// Registers Takely as a login item. Ad-hoc builds may need a one-time approval in System Settings › Login Items.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .onChange(of: enabled) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
}
