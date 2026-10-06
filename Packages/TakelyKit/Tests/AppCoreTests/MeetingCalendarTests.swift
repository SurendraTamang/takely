import Foundation
import Testing

@testable import AppCore

@Suite struct MeetingCalendarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theEventWithTheCallsLinkWins() {
        let lunch = MeetingCalendar.Event(title: "Lunch", start: now - 600, end: now + 1800)
        let sync = MeetingCalendar.Event(
            title: "Weekly sync", start: now - 1200, end: now + 1800, details: "Join: https://meet.google.com/abc-defg-hij")
        let offsite = MeetingCalendar.Event(title: "Offsite", start: now - 7200, end: now + 86_400, isAllDay: true)
        #expect(MeetingCalendar.event(for: "Google Meet", among: [lunch, sync, offsite], at: now) == sync)
        // No link to go by: only the event under way, if it's the only one (not a "Lunch" block during a call).
        #expect(MeetingCalendar.event(for: "Zoom", among: [lunch, sync, offsite], at: now) == nil)
        #expect(MeetingCalendar.event(for: "Zoom", among: [lunch, offsite], at: now) == lunch)
    }

    @Test func backToBackCallsTakeTheOneStartingNearestNow() {
        let ending = MeetingCalendar.Event(title: "First", start: now - 1680, end: now + 120, details: "https://zoom.us/j/1")
        let starting = MeetingCalendar.Event(title: "Second", start: now + 120, end: now + 1920, details: "https://zoom.us/j/2")
        #expect(MeetingCalendar.event(for: "Zoom", among: [ending, starting], at: now) == starting)
    }

    @Test func onlyEventsUnderWayOrAboutToStartCount() {
        let soon = MeetingCalendar.Event(title: "Standup", start: now + 120, end: now + 1020)
        let later = MeetingCalendar.Event(title: "1:1", start: now + 3600, end: now + 5400)
        let over = MeetingCalendar.Event(title: "Earlier", start: now - 3600, end: now - 60)
        #expect(MeetingCalendar.event(for: "Zoom", among: [later, over, soon], at: now) == soon)
        #expect(MeetingCalendar.event(for: "Zoom", among: [later, over], at: now) == nil)
    }

    @Test func titleNamesTheDay() {
        let event = MeetingCalendar.Event(title: " Weekly sync ", start: now, end: now + 60)
        let title = MeetingCalendar.title(of: event, locale: Locale(identifier: "en_GB"))
        #expect(title.hasPrefix("Weekly sync – ") && title.contains("Jan"))
    }
}
