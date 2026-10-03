import AppKit
import Sparkle

/// Sparkle 2 updates: checks the appcast (EdDSA-signed, on top of Apple's notarization) automatically, and on
/// "Check for Updates…". Off in builds without a feed (local and open-source builds).
@MainActor
final class Updates {
    /// A menu bar app has no Dock icon or windows in front: scheduled update alerts are brought forward gently
    /// (Sparkle's guidance for background apps) instead of appearing behind other apps.
    private let reminders = GentleReminders()
    private var controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        guard !feed.isEmpty, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: reminders)
    }

    var isAvailable: Bool { controller != nil }

    func check() { controller?.checkForUpdates(nil) }
}

final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState)
    {
        if handleShowingUpdate, !state.userInitiated { NSApp.activate() }
    }
}
