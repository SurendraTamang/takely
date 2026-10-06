import Testing

@testable import AppCore

@Suite struct WindowMatchTests {
    let windows = [
        WindowMatch.Candidate(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "general – Safari tips"),
        WindowMatch.Candidate(app: "Safari", bundleID: "com.apple.Safari", title: "Apple"),
        WindowMatch.Candidate(app: "Safari", bundleID: "com.apple.Safari", title: "Docs"),
        WindowMatch.Candidate(app: "Xcode", bundleID: "com.apple.dt.Xcode", title: "Takely — RecordingCoordinator.swift"),
    ]

    @Test func appNameBeatsATitleMentioningIt() {
        #expect(WindowMatch.best("safari", among: windows) == 1)  // the frontmost Safari window, not Slack's title
        #expect(WindowMatch.best("com.apple.dt.Xcode", among: windows) == 3)
        #expect(WindowMatch.best("Xco", among: windows) == 3)
        #expect(WindowMatch.best("docs", among: windows) == 2)
        #expect(WindowMatch.best("recordingcoordinator", among: windows) == 3)
        #expect(WindowMatch.best("Finder", among: windows) == nil)
        #expect(WindowMatch.best("  ", among: windows) == nil)
    }
}
