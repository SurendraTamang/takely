import SwiftUI
import ScreenCaptureKit
import AVFoundation

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()
    @State private var isHovering = false
    @State private var permissionGranted = false

    var body: some View {
        ZStack {
            // Background
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            VStack(spacing: 0) {
                // Header
                HeaderView(isRecording: recorder.isRecording)

                Divider().opacity(0.3)

                // Main Content
                ScrollView {
                    VStack(spacing: 16) {
                        // Display Selector or Status
                        if recorder.isRecording {
                            RecordingStatusView(
                                duration: recorder.recordingDuration,
                                formatDuration: recorder.formatDuration
                            )
                        } else {
                            DisplaySelectorView(
                                displays: recorder.availableDisplays,
                                selectedDisplay: $recorder.selectedDisplay,
                                onRefresh: {
                                    Task { await recorder.refreshAvailableDisplays() }
                                }
                            )
                        }

                        // Audio Controls
                        AudioControlsView(
                            captureSystemAudio: $recorder.captureSystemAudio,
                            captureMicrophone: $recorder.captureMicrophone,
                            isRecording: recorder.isRecording
                        )

                        // Record Button
                        RecordButton(
                            isRecording: recorder.isRecording,
                            isHovering: $isHovering,
                            action: {
                                Task {
                                    if recorder.isRecording {
                                        await recorder.stopRecording()
                                    } else {
                                        await recorder.startRecording()
                                    }
                                }
                            }
                        )

                        // Error Message
                        if let error = recorder.errorMessage {
                            ErrorMessageView(message: error)
                        }
                    }
                    .padding(20)
                }

                Divider().opacity(0.3)

                // Footer - Always visible
                FooterView()
            }
        }
        .frame(width: 320, height: 400)
        .onAppear {
            requestAllPermissions()
        }
    }

    private func requestAllPermissions() {
        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("Microphone permission: \(granted)")
        }

        // Request screen recording permission by trying to get content
        Task {
            do {
                _ = try await SCShareableContent.current
                await MainActor.run {
                    permissionGranted = true
                }
            } catch {
                print("Screen recording permission needed: \(error)")
                // Open System Preferences
                await MainActor.run {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            await recorder.refreshAvailableDisplays()
        }
    }
}

// MARK: - Header View
struct HeaderView: View {
    let isRecording: Bool
    @State private var pulse = false

    var body: some View {
        HStack {
            Circle()
                .fill(isRecording ? Color.red : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .animation(
                    isRecording ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                    value: pulse
                )
                .onChange(of: isRecording) { _, newValue in
                    pulse = newValue
                }

            Text("Screen Recorder")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if isRecording {
                Text("REC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Display Selector
struct DisplaySelectorView: View {
    let displays: [SCDisplay]
    @Binding var selectedDisplay: SCDisplay?
    let onRefresh: () -> Void

    var body: some View {
        if displays.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)

                Text("Screen Recording Permission Required")
                    .font(.system(size: 12, weight: .medium))

                Text("Enable in System Settings → Privacy & Security → Screen Recording")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Refresh") {
                        onRefresh()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            HStack {
                Image(systemName: "display")
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedDisplay) {
                    ForEach(displays, id: \.displayID) { display in
                        Text("Display \(display.displayID)")
                            .tag(display as SCDisplay?)
                    }
                }
                .labelsHidden()

                Spacer()

                if let display = selectedDisplay {
                    Text("\(display.width)×\(display.height)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Recording Status View
struct RecordingStatusView: View {
    let duration: TimeInterval
    let formatDuration: (TimeInterval) -> String
    @State private var blink = false

    var body: some View {
        VStack(spacing: 8) {
            Text(formatDuration(duration))
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .foregroundColor(.primary)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .opacity(blink ? 0.3 : 1.0)

                Text("Recording...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                blink = true
            }
        }
    }
}

// MARK: - Audio Controls
struct AudioControlsView: View {
    @Binding var captureSystemAudio: Bool
    @Binding var captureMicrophone: Bool
    let isRecording: Bool

    var body: some View {
        VStack(spacing: 6) {
            AudioToggle(
                icon: "speaker.wave.2.fill",
                title: "System Audio",
                subtitle: "YouTube, Music, Apps",
                isOn: $captureSystemAudio,
                isDisabled: isRecording
            )

            AudioToggle(
                icon: "mic.fill",
                title: "Microphone",
                subtitle: "Your voice",
                isOn: $captureMicrophone,
                isDisabled: isRecording
            )
        }
    }
}

struct AudioToggle: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? .accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isDisabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isDisabled ? 0.5 : 1)
    }
}

// MARK: - Record Button
struct RecordButton: View {
    let isRecording: Bool
    @Binding var isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(isRecording ? Color.gray.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 3)
                    .frame(width: 64, height: 64)

                if isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary)
                        .frame(width: 20, height: 20)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 48, height: 48)
                }
            }
            .scaleEffect(isHovering ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .padding(.vertical, 4)
    }
}

// MARK: - Error Message
struct ErrorMessageView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Footer
struct FooterView: View {
    var body: some View {
        HStack {
            Image(systemName: "folder")
                .font(.system(size: 10))
            Text("Desktop")
                .font(.system(size: 10))

            Spacer()

            Text("MOV • H.264 • 30fps")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }
}

// MARK: - Visual Effect
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    ContentView()
}
