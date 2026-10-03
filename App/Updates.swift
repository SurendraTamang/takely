import Foundation
import Sparkle

/// Sparkle 2 updates: checks the appcast (EdDSA-signed, on top of Apple's notarization) automatically, and on
/// "Check for Updates…". Off in builds without a feed (local and open-source builds).
@MainActor
final class Updates {
    private let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        controller =
            feed.isEmpty || key.isEmpty
            ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func check() { controller?.checkForUpdates(nil) }
}
