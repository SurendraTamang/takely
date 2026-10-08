import Foundation

/// Picks the window an automation `start --window <text>` means, from on-screen windows listed front to back.
public enum WindowMatch {
    public struct Candidate: Sendable, Equatable {
        public var app: String
        public var bundleID: String
        public var title: String
        /// Size in points (width × height).
        public var area: Double

        public init(app: String, bundleID: String, title: String, area: Double = 0) {
            self.app = app
            self.bundleID = bundleID
            self.title = title
            self.area = area
        }
    }

    /// The index of the best match: the app's exact name, then its bundle ID, then an app name containing the text,
    /// then a window title containing it (case-insensitive). Within that, the largest window — an app's main window,
    /// not a toolbar or tab strip it keeps in front (iTerm2 has a 68-point-high one) — frontmost on a tie. Nil if none.
    public static func best(_ query: String, among windows: [Candidate]) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let tiers: [(Candidate) -> Bool] = [
            { $0.app.lowercased() == q }, { $0.bundleID.lowercased() == q }, { $0.app.lowercased().contains(q) },
            { $0.title.lowercased().contains(q) },
        ]
        for tier in tiers {
            let matches = windows.indices.filter { tier(windows[$0]) }
            if let best = matches.min(by: { windows[$0].area > windows[$1].area || (windows[$0].area == windows[$1].area && $0 < $1) }) {
                return best
            }
        }
        return nil
    }
}
