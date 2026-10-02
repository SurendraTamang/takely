import Foundation

/// What the Mac looks like right now, for meeting detection: which apps have the microphone open, and the titles of
/// their windows on screen.
public struct MeetingSnapshot: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var bundleID: String
        public var id: UInt32
        public var title: String

        public init(bundleID: String, id: UInt32, title: String) {
            self.bundleID = bundleID
            self.id = id
            self.title = title
        }
    }

    public var micUsers: Set<String>
    public var windows: [Window]

    public init(micUsers: Set<String>, windows: [Window]) {
        self.micUsers = micUsers
        self.windows = windows
    }
}

/// A call in progress: which service, and its window when one was found (recorded instead of the whole display).
public struct Meeting: Sendable, Equatable {
    public var service: String
    public var bundleID: String
    public var windowID: UInt32?
}

/// Spots calls the way meeting-notes apps do: a meeting app (or a browser showing a meeting page) has the microphone
/// open. Brief mic use (a settings preview) isn't a call: it must last `startAfter`; a call ends once the mic has
/// been released for `endAfter` (rejoining or switching devices doesn't end it).
public struct MeetingWatcher: Sendable {
    public enum Event: Sendable, Equatable {
        case started(Meeting)
        case ended(Meeting)
    }

    static let apps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime", "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex",
        "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    /// Meeting pages, by the browser window's title.
    static func webService(_ title: String) -> String? {
        let t = title.lowercased()
        if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("google meet") || t.contains("meet.google.com") {
            return "Google Meet"
        }
        if t.contains("zoom meeting") || t.contains("zoom.us") { return "Zoom" }
        if t.contains("microsoft teams") || t.contains("| teams") { return "Microsoft Teams" }
        if t.contains("whereby") { return "Whereby" }
        return nil
    }

    /// A helper process's bundle (com.google.Chrome.helper, us.zoom.CptHost…) as its app's, when it's one we know.
    public static func owningApp(_ bundleID: String) -> String {
        let known = Set(apps.keys).union(browsers)
        return known.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? bundleID
    }

    public static let startAfter = 3.0
    public static let endAfter = 15.0

    public private(set) var current: Meeting?
    private var candidate: (meeting: Meeting, since: Date)?
    private var quietSince: Date?

    public init() {}

    public mutating func update(_ snapshot: MeetingSnapshot, now: Date = .now) -> Event? {
        let found = Self.meeting(in: snapshot)
        if let current {
            if found?.bundleID == current.bundleID || snapshot.micUsers.contains(current.bundleID) {
                quietSince = nil
                return nil
            }
            let quiet = quietSince ?? now
            quietSince = quiet
            guard now.timeIntervalSince(quiet) >= Self.endAfter else { return nil }
            self.current = nil
            quietSince = nil
            return .ended(current)
        }
        guard let found else {
            candidate = nil
            return nil
        }
        if let candidate, candidate.meeting.bundleID == found.bundleID {
            guard now.timeIntervalSince(candidate.since) >= Self.startAfter else { return nil }
            self.candidate = nil
            current = found
            return .started(found)
        }
        candidate = (found, now)
        return nil
    }

    /// A meeting app using the mic, or a browser using it while showing a meeting page.
    static func meeting(in snapshot: MeetingSnapshot) -> Meeting? {
        for bundle in snapshot.micUsers.sorted() {
            if let service = apps[bundle] {
                let window = snapshot.windows.first { $0.bundleID == bundle && !$0.title.isEmpty }
                return Meeting(service: service, bundleID: bundle, windowID: window?.id)
            }
            if browsers.contains(bundle),
                let (window, service) = snapshot.windows.lazy.filter({ $0.bundleID == bundle })
                    .compactMap({ w in webService(w.title).map { (w, $0) } }).first
            {
                return Meeting(service: service, bundleID: bundle, windowID: window.id)
            }
        }
        return nil
    }
}
