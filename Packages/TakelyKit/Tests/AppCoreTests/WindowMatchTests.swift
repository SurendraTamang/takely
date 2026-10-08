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

    /// An app's main window, not a strip it keeps in front of it (seen live: iTerm2's 1512×68 window).
    @Test func theAppsMainWindowNotAStripInFront() {
        let iTerm = [
            WindowMatch.Candidate(app: "iTerm2", bundleID: "com.googlecode.iterm2", title: "", area: 1512 * 68),
            WindowMatch.Candidate(app: "iTerm2", bundleID: "com.googlecode.iterm2", title: "", area: 1512 * 913),
        ]
        #expect(WindowMatch.best("iTerm2", among: iTerm) == 1)
        let equal = [
            WindowMatch.Candidate(app: "Notes", bundleID: "com.apple.Notes", title: "A", area: 100),
            WindowMatch.Candidate(app: "Notes", bundleID: "com.apple.Notes", title: "B", area: 100),
        ]
        #expect(WindowMatch.best("Notes", among: equal) == 0)  // same size: the front one
    }
}
