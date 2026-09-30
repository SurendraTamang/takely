import AppCore
import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// The "Recording ready" notification (Copy / Reveal; click opens QuickTime), failure notifications and
/// VoiceOver announcements. Ready falls back to revealing in Finder when notifications are denied or can't be posted.
@MainActor
final class ReadyNotifier: NSObject, RecordingFeedback, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private static let category = "recording-ready"
    private static let copyAction = "copy"
    private static let revealAction = "reveal"

    /// Must run at launch: actions only arrive if the delegate is set before the user clicks.
    func activate() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.copyAction, title: "Copy"),
                    UNNotificationAction(identifier: Self.revealAction, title: "Reveal in Finder"),
                ],
                intentIdentifiers: [])
        ])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func recordingReady(_ url: URL, duration: Double) async {
        announce("Recording ready")
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            await post(url, duration: duration)
        case .notDetermined:
            // First recording ever: ask now rather than silently falling back to Finder, but don't await the
            // answer — the controller stays busy (and a quit waits) until this returns.
            Task {
                if await requestAuthorization() { await post(url, duration: duration) } else { reveal(url) }
            }
        default:
            reveal(url)
        }
    }

    private func post(_ url: URL, duration: Double) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording ready"
        content.body = "\(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) · \(url.lastPathComponent)"
        content.categoryIdentifier = Self.category
        content.sound = .default
        content.userInfo = ["path": url.path]
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            reveal(url)
        }
    }

    /// A plain notification (no actions; clicking does nothing). Never asks for permission: a system quit waits for this.
    func recordingFailed(_ message: String) async {
        announce(message)
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Takely"
        content.body = message
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        let url = URL(filePath: path)
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.copyAction: Self.copy(url)
            case Self.revealAction: self.reveal(url)
            default: Self.openInQuickTime(url)
            }
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Puts the file itself on the clipboard, so pasting into Messages, Mail or Slack attaches the video.
    private static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    private static func openInQuickTime(_ url: URL) {
        if let quickTime = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") {
            NSWorkspace.shared.open([url], withApplicationAt: quickTime, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
