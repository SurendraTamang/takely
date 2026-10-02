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
        #expect(watcher.update(idle, now: t0 + 100) == nil)
        #expect(watcher.update(idle, now: t0 + 115) == .ended(meeting))
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
    }
}
