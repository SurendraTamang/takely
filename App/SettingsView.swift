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
    let sharing: Sharing

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Recording", systemImage: "record.circle") { recording }
            Tab("Shortcuts", systemImage: "keyboard") { shortcuts }
            Tab("Share", systemImage: "link") { ShareSettingsView(sharing: sharing) }
            Tab("Automation", systemImage: "terminal") { automation }
            Tab("Permissions", systemImage: "lock.shield") { permissionsTab }
        }
        .frame(width: 520, height: 480)
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
            Toggle(isOn: $settings.removeEcho) {
                Text("Remove speaker echo")
                Text(
                    settings.systemAudio && settings.microphone
                        ? "Keeps sound from your speakers out of the microphone. The original is kept in the recording."
                        : "Needs System audio and Microphone.")
            }
            .disabled(!(settings.systemAudio && settings.microphone))
            Toggle("Countdown before recording", isOn: $settings.countdown)
            Toggle(isOn: $settings.detectMeetings) {
                Text("Offer to record meetings (Zoom, Teams, Google Meet…)")
                Text("Meetings in a browser are recognized by their window title, which needs Screen Recording permission.")
            }
            Toggle(isOn: $settings.autoRecordMeetings) {
                Text("Always record meetings, without asking")
                Text("Tell everyone in the call that you're recording: in many places it's required by law.")
            }
            .disabled(!settings.detectMeetings)
            Toggle("Show recording controls", isOn: $settings.showControls)
            Toggle("Scroll the prompter while recording", isOn: $settings.prompterFollowsRecording)
            #if canImport(TakelyPro)
                Section("Takely Pro") {
                    Toggle("Transcribe recordings (captions)", isOn: $settings.transcribe)
                    Toggle("Burn captions into the video", isOn: $settings.burnInCaptions)
                        .disabled(!settings.transcribe)
                    Toggle("AI title, summary and chapter names", isOn: $settings.aiSummary)
                        .disabled(!settings.transcribe)
                    Toggle("Blur secrets on screen (keys, emails, card numbers)", isOn: $settings.redactSecrets)
                    Toggle("Zoom in on clicks automatically", isOn: $settings.autoZoom)
                    Toggle("Remove long pauses automatically", isOn: $settings.removeSilences)
                        .disabled(!settings.transcribe)
                    Toggle("Prompter follows my voice", isOn: $settings.prompterFollowsVoice)
                    Toggle("Live speaking coach (pace, filler words)", isOn: $settings.liveCoach)
                    Text("On this Mac, in the system language. AI needs Apple Intelligence (System Settings › Apple Intelligence & Siri).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            #endif
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
            KeyboardShortcuts.Recorder("Show / hide camera:", name: .toggleCamera)
            KeyboardShortcuts.Recorder("Show / hide prompter:", name: .togglePrompter)
            KeyboardShortcuts.Recorder("Oops, retake:", name: .retake)
            KeyboardShortcuts.Recorder("Add marker:", name: .addMarker)
            KeyboardShortcuts.Recorder("Draw on screen:", name: .toggleDrawing)
            Text("On some keyboard layouts ⌥⇧ + a letter types a special character; pick another shortcut if you need it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    /// The command that puts the bundled `takely` tool on the PATH (the convention VS Code's `code` uses).
    private var installCommand: String {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/takely").path(percentEncoded: false)
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(tool)\" /usr/local/bin/takely"
    }

    private var automation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command-line tool").font(.headline)
            Text("Run this once in Terminal to use `takely record start`, `takely record stop --json` and more:")
                .font(.callout)
            HStack(alignment: .top) {
                Text(installCommand).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                }
            }
            Toggle("Let takely:// links control recording without asking", isOn: $settings.allowLinkControl)
            Text("Off: a link asks you first (any web page or app can open a link). Links never receive the video's location.")
                .font(.caption).foregroundStyle(.secondary)
            Text(
                "Shortcuts and Siri: Takely's actions (Start Recording, Stop Recording returns the video, Add Marker…) are in the Shortcuts app. Links: takely://record/start?countdown=0, takely://record/stop (x-callback-url)."
            )
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
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
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle(
            "Launch at login",
            isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    status = SMAppService.mainApp.status
                }))
        if status == .requiresApproval {
            HStack {
                Text("Allow Takely in System Settings › Login Items.").font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
}
