import AppCore
import AppKit
import ProjectKit
import SwiftUI
@preconcurrency import UserNotifications

/// The "Recording ready" notification (Copy / Reveal; click opens QuickTime), failure notifications and
/// VoiceOver announcements. Ready falls back to revealing in Finder when notifications are denied or can't be posted.
@MainActor
final class ReadyNotifier: NSObject, RecordingFeedback, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private static let category = "recording-ready"
    /// A line added to the next Ready notification (the live coach's recap), then cleared.
    var recap: String?
    private static let copyAction = "copy"
    private static let revealAction = "reveal"
    private static let reviewAction = "review"
    /// Opens the blur review for a recording's bundle (the notification's Review action).
    var onReview: ((ProjectBundle) -> Void)?
    private static let editAction = "edit"
    private static let shareAction = "share"
    private static let failedExportCategory = "export-failed"
    private static let retryAction = "retry"
    /// Exports a saved recording again (the failure notification's Retry).
    var onRetryExport: ((ProjectBundle) -> Void)?
    private static let linkCategory = "link-ready"
    /// Uploads a recording to the user's bucket (the Share action), and runs after each export (auto-upload).
    var onShare: ((ProjectBundle) -> Void)?
    var onExported: ((URL) -> Void)?
    private static let meetingCategory = "meeting"
    private static let meetingRequest = "meeting-offer"
    private nonisolated static let recordMeetingAction = "record-meeting"
    /// Starts recording the meeting that was just detected (the notification's Record action).
    var onRecordMeeting: (() -> Void)?
    /// Opens the editor (Takely Pro); set before `activate`, which offers the Edit action only when it's set.
    var onEdit: ((ProjectBundle) -> Void)?

    /// Must run at launch: actions only arrive if the delegate is set before the user clicks.
    func activate() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.copyAction, title: "Copy"),
                    UNNotificationAction(identifier: Self.revealAction, title: "Reveal in Finder"),
                    UNNotificationAction(identifier: Self.reviewAction, title: "Review Blurs", options: .foreground),
                    UNNotificationAction(identifier: Self.shareAction, title: "Share Link"),
                ] + (onEdit == nil ? [] : [UNNotificationAction(identifier: Self.editAction, title: "Edit", options: .foreground)]),
                intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.linkCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.failedExportCategory,
                actions: [
                    UNNotificationAction(identifier: Self.retryAction, title: "Retry"),
                    UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder"),
                ], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.meetingCategory,
                actions: [UNNotificationAction(identifier: Self.recordMeetingAction, title: "Record")],
                intentIdentifiers: []),
        ])
    }

    /// "Google Meet call started — Record?" (replaced by the next offer; withdrawn when the call ends).
    func meetingDetected(_ service: String) async {
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, await requestAuthorization() { status = .authorized }
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service) call started"
        content.body = "Record it? Let everyone know you're recording."
        content.categoryIdentifier = Self.meetingCategory
        content.userInfo = ["meeting": true]
        try? await center.add(UNNotificationRequest(identifier: Self.meetingRequest, content: content, trigger: nil))
    }

    /// "Link copied": the shared recording's link is on the clipboard (clicking opens the page).
    func linkReady(_ link: URL, title: String) async {
        announce("Link copied")
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Link copied"
        content.body = "\(title)\n\(link.absoluteString)"
        content.categoryIdentifier = Self.linkCategory
        content.userInfo = ["link": link.absoluteString]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func withdrawMeetingOffer() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingRequest])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func recordingReady(_ url: URL, duration: Double, title: String?) async {
        announce("Recording ready")
        onExported?(url)
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            await post(url, duration: duration, title: title)
        case .notDetermined:
            // First recording ever: ask now rather than silently falling back to Finder, but don't await the
            // answer — the controller stays busy (and a quit waits) until this returns.
            Task {
                if await requestAuthorization() { await post(url, duration: duration, title: title) } else { reveal(url) }
            }
        default:
            reveal(url)
        }
    }

    private func post(_ url: URL, duration: Double, title: String?) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording ready"
        let length = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
        content.body = title.map { "\($0) · \(length)" } ?? "\(length) · \(url.lastPathComponent)"
        let blurred =
            ProjectBundle.containing(url).flatMap { try? $0.readRedactions() }?.filter { $0.enabled && $0.kind != .manual }.count ?? 0
        if blurred > 0 { content.body += "\n\(blurred) secret\(blurred == 1 ? "" : "s") blurred" }
        if let recap {
            content.body += "\n\(recap)"
            self.recap = nil
        }
        content.categoryIdentifier = Self.category
        content.sound = .default
        content.userInfo = ["path": url.path]
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            reveal(url)
        }
    }

    /// "Recording saved, but export failed" with Retry and Show in Finder (the saved recording).
    func exportFailed(_ message: String, bundle: ProjectBundle) async {
        announce(message)
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Export failed"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Self.failedExportCategory
        content.userInfo = ["path": bundle.url.path, "failedExport": true]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
        if response.notification.request.content.userInfo["meeting"] != nil {
            // Only the Record button records: clicking the notification to read or clear it never does.
            if response.actionIdentifier == Self.recordMeetingAction { await MainActor.run { self.onRecordMeeting?() } }
            return
        }
        if let link = (response.notification.request.content.userInfo["link"] as? String).flatMap(URL.init(string:)) {
            await MainActor.run { _ = NSWorkspace.shared.open(link) }
            return
        }
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        if response.notification.request.content.userInfo["failedExport"] != nil {
            let bundle = ProjectBundle(url: URL(filePath: path))
            let action = response.actionIdentifier
            await MainActor.run {
                switch action {
                case Self.retryAction: self.onRetryExport?(bundle)
                case Self.revealAction, UNNotificationDefaultActionIdentifier: self.reveal(bundle.url)
                default: break
                }
            }
            return
        }
        let url = URL(filePath: path)
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.copyAction: Self.copy(url)
            case Self.revealAction: self.reveal(url)
            case Self.reviewAction: ProjectBundle.containing(url).map { self.onReview?($0) }
            case Self.editAction: ProjectBundle.containing(url).map { self.onEdit?($0) }
            case Self.shareAction: ProjectBundle.containing(url).map { self.onShare?($0) }
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
