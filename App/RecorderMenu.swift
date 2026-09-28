import CaptureKit
import ProjectKit
import SwiftUI

struct RecorderMenu: View {
    @Bindable var recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch recorder.phase {
            case .idle:
                setup
            case .recording, .paused:
                controls
            case .exporting(let progress):
                ProgressView("Exporting…", value: progress)
            }
            if let error = recorder.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if let url = recorder.lastExport {
                    Button("Show Last Recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("Quit Takely") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
        .task { await recorder.refreshDisplays() }
    }

    private var setup: some View {
        Group {
            Picker("Display", selection: $recorder.displayID) {
                ForEach(recorder.displays, id: \.displayID) { display in
                    Text("\(display.width) × \(display.height)").tag(Optional(display.displayID))
                }
            }
            Toggle("Camera", systemImage: "video", isOn: $recorder.camera)
            Toggle("System Audio", systemImage: "speaker.wave.2", isOn: $recorder.systemAudio)
            Toggle("Microphone", systemImage: "mic", isOn: $recorder.microphone)
            Picker("Quality", selection: $recorder.resolution) {
                Text("720p").tag(Resolution.p720)
                Text("1080p").tag(Resolution.p1080)
                Text("Native").tag(Resolution.native)
            }
            Picker("Frame Rate", selection: $recorder.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Codec", selection: $recorder.codec) {
                Text("HEVC").tag(VideoCodec.hevc)
                Text("H.264").tag(VideoCodec.h264)
            }
            Button {
                Task { await recorder.start() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(recorder.displays.isEmpty)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Text(recorder.elapsed.formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 40, weight: .light, design: .monospaced))
                .accessibilityLabel("Elapsed time \(recorder.elapsed.formatted(.units(allowed: [.minutes, .seconds])))")
            HStack {
                Button {
                    Task { await recorder.togglePause() }
                } label: {
                    Label(
                        recorder.phase == .paused ? "Resume" : "Pause", systemImage: recorder.phase == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }
}
