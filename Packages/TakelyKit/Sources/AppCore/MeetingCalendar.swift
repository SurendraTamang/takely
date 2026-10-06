import Foundation

/// Names a meeting recording after the calendar event it belongs to ("Weekly sync – 6 Oct"). The app reads the events
/// (EventKit); this picks one, so the choice is testable.
public enum MeetingCalendar {
    public struct Event: Sendable, Equatable {
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// Where a meeting link may be: the event's URL, location and notes.
        public var details: String

        public init(title: String, start: Date, end: Date, isAllDay: Bool = false, details: String = "") {
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.details = details
        }
    }

    /// Link text that marks an event as a call on `service`.
    static func hints(_ service: String) -> [String] {
        switch service {
        case "Google Meet": ["meet.google.com"]
        case "Zoom": ["zoom.us", "zoom.com"]
        case "Microsoft Teams": ["teams.microsoft.com", "teams.live.com"]
        case "Webex": ["webex.com"]
        case "FaceTime": ["facetime.apple.com"]
        case "Whereby": ["whereby.com"]
        default: []
        }
    }

    /// The event the call belongs to: one under way (or starting within 5 minutes), not all-day. Among those with the
    /// service's link, the one starting nearest to now (back-to-back calls); without a link, only an event that's the
    /// one under way (a "Lunch" block during an ad-hoc call isn't the call). Nil if none fits. `events` should already
    /// leave out cancelled and declined ones.
    public static func event(for service: String, among events: [Event], at now: Date) -> Event? {
        let current = events.filter { !$0.isAllDay && $0.start <= now.addingTimeInterval(300) && $0.end > now }
        let hints = hints(service)
        let linked = current.filter { event in hints.contains { event.details.lowercased().contains($0) } }
        if let nearest = linked.min(by: { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }) {
            return nearest
        }
        return current.count == 1 ? current[0] : nil
    }

    /// "Weekly sync – 6 Oct": the event's title and its day (recordings of a recurring meeting stay apart).
    public static func title(of event: Event, locale: Locale = .current) -> String {
        let name = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = event.start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return name.isEmpty ? date : "\(name) – \(date)"
    }
}
