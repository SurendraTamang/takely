import Foundation
import Testing

@testable import AppCore

@Suite struct MeetingWatcherTests {
    let meet = MeetingSnapshot(
        micUsers: ["com.google.Chrome"],
        windows: [
            .init(bundleID: "com.google.Chrome", id: 7, title: "Inbox - Gmail"),
            .init(bundleID: "com.google.Chrome", id: 9, title: "Meet - abc-defg-hij"),
        ])
    let idle = MeetingSnapshot(micUsers: [], windows: [])

    @Test func aGoogleMeetCallStartsAfterAMomentAndEndsAfterTheMicIsReleased() {
        var watcher = MeetingWatcher()
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(watcher.update(meet, now: t0) == nil)  // could be a mic preview
        #expect(watcher.update(meet, now: t0 + 1) == nil)
        let meeting = Meeting(service: "Google Meet", bundleID: "com.google.Chrome", windowID: 9)
        #expect(watcher.update(meet, now: t0 + 3) == .started(meeting))
        #expect(watcher.update(idle, now: t0 + 60) == nil)  // a hiccup (switching devices) doesn't end it
        #expect(watcher.update(meet, now: t0 + 65) == nil)
        #expect(!watcher.isEnding)
        #expect(watcher.update(idle, now: t0 + 100) == nil)
        #expect(watcher.isEnding)  // Record from the notification now would start a stray recording
        #expect(watcher.update(idle, now: t0 + 115) == .ended(meeting))
        #expect(!watcher.isEnding)
        #expect(watcher.current == nil)
    }

    @Test func briefMicUseAndOrdinaryBrowsingArentMeetings() {
        var watcher = MeetingWatcher()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = watcher.update(meet, now: t0)
        #expect(watcher.update(idle, now: t0 + 1) == nil)
        #expect(watcher.update(meet, now: t0 + 2) == nil)  // starts counting again
        let dictation = MeetingSnapshot(
            micUsers: ["com.google.Chrome"], windows: [.init(bundleID: "com.google.Chrome", id: 1, title: "Docs")])
        #expect(MeetingWatcher.meeting(in: dictation) == nil)
        #expect(MeetingWatcher.meeting(in: MeetingSnapshot(micUsers: ["com.apple.VoiceMemos"], windows: [])) == nil)
    }

    @Test func meetingAppsAreRecognizedByTheirMicUse() {
        let zoom = MeetingSnapshot(micUsers: ["us.zoom.xos"], windows: [.init(bundleID: "us.zoom.xos", id: 3, title: "Zoom Meeting")])
        #expect(MeetingWatcher.meeting(in: zoom) == Meeting(service: "Zoom", bundleID: "us.zoom.xos", windowID: 3))
        #expect(MeetingWatcher.webService("Meet – Weekly sync") == "Google Meet")
        #expect(MeetingWatcher.webService("Chat | Microsoft Teams") == "Microsoft Teams")
        #expect(MeetingWatcher.owningApp("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(MeetingWatcher.owningApp("us.zoom.xos") == "us.zoom.xos")
        #expect(MeetingWatcher.owningApp("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan") == "com.google.Chrome")
        #expect(MeetingWatcher.owningApp("com.apple.WebKit.GPU") == "com.apple.Safari")
        // A Slack huddle: the display, not Slack's main window (channels, DMs).
        let huddle = MeetingSnapshot(
            micUsers: ["com.tinyspeck.slackmacgap"], windows: [.init(bundleID: "com.tinyspeck.slackmacgap", id: 4, title: "general - Acme")]
        )
        #expect(MeetingWatcher.meeting(in: huddle)?.windowID == nil)
        // avconferenced without FaceTime open isn't a call.
        #expect(MeetingWatcher.meeting(in: MeetingSnapshot(micUsers: ["com.apple.FaceTime"], windows: [])) == nil)
        // Safari's web content process with Meet in front is.
        let safari = MeetingSnapshot(
            micUsers: ["com.apple.Safari"], windows: [.init(bundleID: "com.apple.Safari", id: 2, title: "Meet - xyz")])
        #expect(MeetingWatcher.meeting(in: safari)?.service == "Google Meet")
    }

    @Test func aZoomCallMutedWithTheMicReleasedGoesOnWhileItsWindowIsOpen() {
        var watcher = MeetingWatcher()
        let t0 = Date(timeIntervalSince1970: 0)
        let window = MeetingSnapshot.Window(bundleID: "us.zoom.xos", id: 3, title: "Zoom Meeting")
        let call = MeetingSnapshot(micUsers: ["us.zoom.xos"], windows: [window])
        _ = watcher.update(call, now: t0)
        #expect(watcher.update(call, now: t0 + 3) == .started(Meeting(service: "Zoom", bundleID: "us.zoom.xos", windowID: 3)))
        let muted = MeetingSnapshot(micUsers: [], windows: [window])
        #expect(watcher.update(muted, now: t0 + 10) == nil)
        #expect(watcher.update(muted, now: t0 + 600) == nil && !watcher.isEnding)  // ten minutes on mute
        #expect(watcher.update(idle, now: t0 + 601) == nil)  // the window closed: the call ended
        #expect(watcher.update(idle, now: t0 + 616) == .ended(Meeting(service: "Zoom", bundleID: "us.zoom.xos", windowID: 3)))
        // At most an hour on the window alone; and a window no longer titled as the call doesn't count.
        var long = MeetingWatcher()
        _ = long.update(call, now: t0)
        _ = long.update(call, now: t0 + 3)
        _ = long.update(muted, now: t0 + 10)
        #expect(long.update(muted, now: t0 + 3_609) == nil)
        _ = long.update(muted, now: t0 + 3_611)
        #expect(long.update(muted, now: t0 + 3_626) != nil)
        var renamed = MeetingWatcher()
        _ = renamed.update(call, now: t0)
        _ = renamed.update(call, now: t0 + 3)
        let chat = MeetingSnapshot(micUsers: [], windows: [.init(bundleID: "us.zoom.xos", id: 3, title: "Zoom Workplace")])
        _ = renamed.update(chat, now: t0 + 10)
        #expect(renamed.update(chat, now: t0 + 25) != nil)
        // Teams' main window can carry a "meeting" title after the call: it never keeps a call going.
        var teams = MeetingWatcher()
        let teamsWindow = MeetingSnapshot.Window(bundleID: "com.microsoft.teams2", id: 8, title: "Chat | Weekly meeting | Microsoft Teams")
        _ = teams.update(MeetingSnapshot(micUsers: ["com.microsoft.teams2"], windows: [teamsWindow]), now: t0)
        _ = teams.update(MeetingSnapshot(micUsers: ["com.microsoft.teams2"], windows: [teamsWindow]), now: t0 + 3)
        _ = teams.update(MeetingSnapshot(micUsers: [], windows: [teamsWindow]), now: t0 + 10)
        #expect(teams.update(MeetingSnapshot(micUsers: [], windows: [teamsWindow]), now: t0 + 25) != nil)
        // A browser's meeting tab doesn't keep a call going: it outlives the call.
        var browser = MeetingWatcher()
        _ = browser.update(meet, now: t0)
        _ = browser.update(meet, now: t0 + 3)
        let tabOnly = MeetingSnapshot(micUsers: [], windows: meet.windows)
        _ = browser.update(tabOnly, now: t0 + 10)
        #expect(browser.update(tabOnly, now: t0 + 25) != nil)
    }
}
