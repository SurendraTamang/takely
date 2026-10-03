import Foundation

/// Whether Takely Pro's features are available, and why (shown in Settings). The open-source app has no Pro and no
/// gate; a Pro build's license manager implements this, and Pro's features check it themselves.
public enum LicenseState: Sendable, Equatable {
    /// A free trial, from first launch.
    case trial(daysLeft: Int)
    /// A license key is active on this Mac.
    case licensed(product: String)
    /// No trial left and no valid key: Pro features are off (the rest of Takely keeps working).
    case locked(reason: String)

    public var unlocksPro: Bool {
        switch self {
        case .trial, .licensed: true
        case .locked: false
        }
    }
}

@MainActor
public protocol LicenseGate: AnyObject {
    var state: LicenseState { get }
}
