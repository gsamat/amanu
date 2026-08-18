import Foundation

/// Everything amanuensis knows about a meeting at the moment it starts recording:
/// what the calendar calls it, who else is invited, and which app is holding
/// the microphone.
///
/// It exists to answer the question you actually have three weeks later, which
/// is never "what happened at 20:39" but "where's that call with the client".
/// So the folder gets a name — `2026.08.17-2039 Integration sync (zoom.us)` —
/// and meta.json gets the rest, including the attendee list, which then goes
/// into the summarizer's prompt where knowing the participants measurably
/// improves what comes back.
///
/// Everything here is optional. A manual recording with no calendar entry and
/// no recognizable app is still a perfectly good recording; it just gets a
/// folder named after the time, exactly as before.
struct MeetingContext {
    /// The calendar event's title.
    var title: String?
    /// Display name of the app holding the mic — "zoom.us", "Google Chrome",
    /// "Telegram". The one piece of context that's available even when the
    /// calendar is empty or switched off.
    var app: String?
    /// Bundle-id families of the call app, for pointing the system-audio tap
    /// at the call rather than at everything the Mac plays.
    var appFamilies: [String] = []
    var attendees: [String] = []
    /// Conference link or location from the calendar event.
    var link: String?
    var scheduledStart: Date?
    var scheduledEnd: Date?

    static let empty = MeetingContext()

    init(
        title: String? = nil,
        app: String? = nil,
        appFamilies: [String] = [],
        attendees: [String] = [],
        link: String? = nil,
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil
    ) {
        self.title = title
        self.app = app
        self.appFamilies = appFamilies
        self.attendees = attendees
        self.link = link
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
    }

    init(meeting: CalendarWatcher.Meeting?, app: String?, appFamilies: [String] = []) {
        self.init(
            title: meeting?.title,
            // An unnameable process is better left out than turned into
            // something meaningless in a folder name.
            app: (app?.isEmpty ?? true) ? nil : app,
            appFamilies: appFamilies,
            attendees: meeting?.attendees ?? [],
            link: meeting?.link,
            scheduledStart: meeting?.start,
            scheduledEnd: meeting?.end
        )
    }

    /// The part of a session folder's name that follows the timestamp, or nil
    /// when nothing is known. Title first because that's what you scan for;
    /// the app in brackets after it, and on its own when there's no title —
    /// "which app was this" beats a bare timestamp every time.
    var folderSuffix: String? {
        let name = Self.sanitize(title, limit: 60)
        let app = Self.sanitize(self.app, limit: 24)
        switch (name, app) {
        case let (name?, app?): return "\(name) (\(app))"
        case let (name?, nil): return name
        case let (nil, app?): return app
        case (nil, nil): return nil
        }
    }

    /// The fields meta.json carries, so a folder can be understood without the
    /// calendar it came from — which may since have changed or been deleted.
    var metaFields: [String: Any] {
        var fields: [String: Any] = [:]
        if let app { fields["app"] = app }

        var calendar: [String: Any] = [:]
        if let title { calendar["title"] = title }
        if !attendees.isEmpty { calendar["attendees"] = attendees }
        if let link { calendar["link"] = link }
        let iso = ISO8601DateFormatter()
        if let scheduledStart { calendar["scheduled_start"] = iso.string(from: scheduledStart) }
        if let scheduledEnd { calendar["scheduled_end"] = iso.string(from: scheduledEnd) }
        if !calendar.isEmpty { fields["calendar"] = calendar }

        return fields
    }

    /// Folder-safe and short: no path separators, no colons (Finder renders
    /// them as slashes), no newlines out of a calendar note, and cut to
    /// something that still reads in a list.
    private static func sanitize(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
}
