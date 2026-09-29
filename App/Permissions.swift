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
            case .screenRecording: "Required to record your screen."
            case .camera: "For the camera bubble (optional)."
            case .microphone: "To record your voice (optional)."
            case .notifications: "To tell you when a recording is ready (optional)."
            }
        }

        var settingsURL: URL? {
            let anchor =
                switch self {
                case .screenRecording: "Privacy_ScreenCapture"
                case .camera: "Privacy_Camera"
                case .microphone: "Privacy_Microphone"
                case .notifications: "Notifications"
                }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    private(set) var granted: [Kind: Bool] = [:]

    func refresh() async {
        granted[.screenRecording] = CGPreflightScreenCaptureAccess()
        granted[.camera] = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        granted[.microphone] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        granted[.notifications] = status == .authorized || status == .provisional
    }

    func request(_ kind: Kind) async {
        switch kind {
        case .screenRecording:
            // Shows the system prompt once; after that only System Settings can change it.
            if !CGRequestScreenCaptureAccess(), let url = kind.settingsURL { NSWorkspace.shared.open(url) }
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        await refresh()
    }
}
