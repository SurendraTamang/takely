import AVFoundation
import AppKit
import CoreGraphics
import Observation
@preconcurrency import UserNotifications

/// Live status of the four permissions Takely uses, for onboarding and Settings.
@MainActor @Observable
final class Permissions {
    enum Kind: CaseIterable, Identifiable {
        case screenRecording, camera, microphone, notifications
        var id: Self { self }

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .notifications: "Notifications"
            }
        }

        var purpose: String {
            switch self {
            case .screenRecording: "Required to record your screen. After allowing it, quit and reopen Takely."
            case .camera: "For the camera bubble (optional)."
            case .microphone: "To record your voice (optional)."
            case .notifications: "To tell you when a recording is ready (optional)."
            }
        }

        var settingsURL: URL? {
            let pane =
                switch self {
                case .screenRecording: "com.apple.preference.security?Privacy_ScreenCapture"
                case .camera: "com.apple.preference.security?Privacy_Camera"
                case .microphone: "com.apple.preference.security?Privacy_Microphone"
                case .notifications: "com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
                }
            return URL(string: "x-apple.systempreferences:\(pane)")
        }
    }

    private(set) var granted: [Kind: Bool] = [:]

    func refresh() async {
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let now: [Kind: Bool] = [
            .screenRecording: CGPreflightScreenCaptureAccess(),
            .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            .notifications: notifications == .authorized || notifications == .provisional,
        ]
        if now != granted { granted = now }  // polled every second: redraw only on change
    }

    /// Asks with the system prompt the first time; once it was answered, only System Settings can change it.
    func request(_ kind: Kind) async {
        switch kind {
        case .screenRecording:
            // CGRequestScreenCaptureAccess returns at once, before the user answers: prompt once, then open Settings.
            if UserDefaults.standard.bool(forKey: "askedScreenRecording") {
                open(kind)
            } else {
                UserDefaults.standard.set(true, forKey: "askedScreenRecording")
                _ = CGRequestScreenCaptureAccess()
            }
        case .camera, .microphone:
            let media: AVMediaType = kind == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            } else {
                open(kind)
            }
        case .notifications:
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            } else {
                open(kind)
            }
        }
        await refresh()
    }

    private func open(_ kind: Kind) {
        if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    }
}
