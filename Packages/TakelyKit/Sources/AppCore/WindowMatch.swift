import Foundation

/// Picks the window an automation `start --window <text>` means, from on-screen windows listed front to back.
public enum WindowMatch {
    public struct Candidate: Sendable, Equatable {
        public var app: String
        public var bundleID: String
        public var title: String

        public init(app: String, bundleID: String, title: String) {
            self.app = app
            self.bundleID = bundleID
            self.title = title
        }
    }

    /// The index of the best match: the app's exact name, then its bundle ID, then an app name containing the text,
    /// then a window title containing it (case-insensitive); the frontmost within each. Nil if none matches.
    public static func best(_ query: String, among windows: [Candidate]) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let tiers: [(Candidate) -> Bool] = [
            { $0.app.lowercased() == q }, { $0.bundleID.lowercased() == q }, { $0.app.lowercased().contains(q) },
            { $0.title.lowercased().contains(q) },
        ]
        for tier in tiers {
            if let index = windows.firstIndex(where: tier) { return index }
        }
        return nil
    }
}
