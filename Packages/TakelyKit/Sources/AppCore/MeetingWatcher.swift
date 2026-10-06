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

    /// Processes that hold the mic for an app: FaceTime's calls run in avconferenced; Safari's pages capture in the
    /// WebKit GPU process (shared by every app with a web view, so Safari still needs a meeting page in front).
    static let aliases = ["com.apple.avconferenced": "com.apple.FaceTime", "com.apple.WebKit.GPU": "com.apple.Safari"]

    /// A helper process's bundle (com.google.Chrome.helper, us.zoom.CptHost…) or an installed web app's
    /// (com.google.Chrome.app.<id>, e.g. the Google Meet app) as its app's, when it's one we know.
    public static func owningApp(_ bundleID: String) -> String {
        if let app = aliases[bundleID] { return app }
        let known = Set(apps.keys).union(browsers)
        return known.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? bundleID
    }

    /// Whether a mic user could be a call (only then are window titles worth reading).
    public static func isCandidate(_ bundleID: String) -> Bool { apps[bundleID] != nil || browsers.contains(bundleID) }

    /// The call's own window, for apps whose call window can be told apart by its title; otherwise none (the
    /// display is recorded rather than, say, Slack's channels).
    static func callWindow(_ bundleID: String, _ title: String) -> Bool {
        let t = title.lowercased()
        switch bundleID {
        case "us.zoom.xos": return t.contains("zoom meeting") || t.contains("zoom webinar")
        case "com.apple.FaceTime": return !t.isEmpty
        case "com.microsoft.teams2", "com.microsoft.teams": return t.contains("meeting") || t.contains("call")
        case "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp": return t.contains("meeting")
        default: return false
        }
    }

    /// Apps whose call window can be told apart and closes when the call ends: while it's on screen (still titled as
    /// the call) the call goes on, even with the mic released (some apps release it on mute) — for at most
    /// `windowOnlyLimit`. Only Zoom: Teams' and Webex's main windows can match their call-window titles and stay open
    /// after the call; browser tabs outlive calls; FaceTime's window stays.
    static let callWindowEndsWithCall: Set<String> = ["us.zoom.xos"]
    static let windowOnlyLimit = 3600.0

    public static let startAfter = 3.0
    public static let endAfter = 15.0

    public private(set) var current: Meeting?
    /// The current call's mic has been released and it ends unless the mic comes back: too late to start recording it.
    public var isEnding: Bool { quietSince != nil }
    private var candidate: (meeting: Meeting, since: Date)?
    private var quietSince: Date?
    /// Since when only the call's window has kept the call going (no mic).
    private var windowOnlySince: Date?

    public init() {}

    public mutating func update(_ snapshot: MeetingSnapshot, now: Date = .now) -> Event? {
        let found = Self.meeting(in: snapshot)
        if let current {
            let heard = found?.bundleID == current.bundleID || snapshot.micUsers.contains(current.bundleID)
            let windowOpen =
                Self.callWindowEndsWithCall.contains(current.bundleID)
                && snapshot.windows.contains { $0.id == current.windowID && Self.callWindow(current.bundleID, $0.title) }
            if heard { windowOnlySince = nil } else if windowOpen { windowOnlySince = windowOnlySince ?? now }
            let windowKeeps = windowOpen && now.timeIntervalSince(windowOnlySince ?? now) < Self.windowOnlyLimit
            if heard || windowKeeps {
                quietSince = nil
                return nil
            }
            let quiet = quietSince ?? now
            quietSince = quiet
            guard now.timeIntervalSince(quiet) >= Self.endAfter else { return nil }
            self.current = nil
            quietSince = nil
            windowOnlySince = nil
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
                let windows = snapshot.windows.filter { $0.bundleID == bundle }
                // avconferenced also serves other system audio/video: it's a call only with FaceTime open.
                if bundle == "com.apple.FaceTime", windows.isEmpty { continue }
                let window = windows.first { callWindow(bundle, $0.title) }
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
