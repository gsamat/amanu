import EventKit
import Foundation

/// Reads the local calendars for two things: a real name for the session
/// folder instead of a bare timestamp, and a second, independent trigger for
/// automatic recording.
///
/// Opt-in (`auto_record.calendar`), because it costs a permission prompt and
/// because a calendar is only a good meeting signal if yours is accurate. The
/// mic-activity trigger needs no permission and no accurate calendar, so it
/// stays the default of the two.
@MainActor
final class CalendarWatcher {
    struct Meeting {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        /// Conference link or location, whichever the event carries — kept so
        /// the recording folder can say where the call actually happened.
        let link: String?
        /// True when the event has other people or a conference link — the
        /// difference between a meeting and "dentist, 15:00".
        let looksLikeCall: Bool
    }

    private let store = EKEventStore()
    private(set) var authorized = false

    /// Ask once, at startup, and only when the calendar trigger is enabled.
    /// Denial is not an error: the mic trigger carries on alone.
    func requestAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorized = true
        case .notDetermined:
            authorized = (try? await store.requestFullAccessToEvents()) ?? false
            if !authorized {
                FileHandle.standardError.write(Data(
                    "calendar access denied — auto-record falls back to mic activity only\n".utf8
                ))
            }
        default:
            authorized = false
            FileHandle.standardError.write(Data(
                "calendar access not granted — sessions will be named by time\n".utf8
            ))
        }
    }

    /// Meetings that started within the last `window` seconds (or are about to,
    /// by up to 30s — calendar clocks and wall clocks disagree slightly) and
    /// look like calls. The auto-record trigger.
    func justStarted(now: Date, window: TimeInterval) -> [Meeting] {
        meetings(around: now, slack: window).filter {
            let sinceStart = now.timeIntervalSince($0.start)
            return sinceStart >= -30 && sinceStart <= window && $0.looksLikeCall
        }
    }

    /// The event that best describes a recording started at `date` — used to
    /// name the session folder even when the recording began some other way.
    /// Prefers something with other people in it over a solo block.
    func bestMatch(for date: Date) -> Meeting? {
        let candidates = meetings(around: date, slack: 8 * 60)
        return candidates.first { $0.looksLikeCall } ?? candidates.first
    }

    // MARK: -

    private func meetings(around date: Date, slack: TimeInterval) -> [Meeting] {
        guard authorized else { return [] }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-slack),
            end: date.addingTimeInterval(slack),
            calendars: calendars
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .map(Self.convert)
            .sorted { $0.start < $1.start }
    }

    private static func convert(_ event: EKEvent) -> Meeting {
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            participant.name
                ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        let haystack = [
            event.location ?? "",
            event.url?.absoluteString ?? "",
            event.hasNotes ? (event.notes ?? "") : "",
        ].joined(separator: " ").lowercased()

        // The link is worth keeping verbatim; the notes are not — they are as
        // often a wall of boilerplate or something private as they are useful.
        let link = [event.url?.absoluteString, event.location]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return Meeting(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: attendees,
            link: link,
            // Self counts as an attendee, so "other people" means more than one.
            looksLikeCall: attendees.count > 1
                || Self.conferenceMarkers.contains { haystack.contains($0) }
        )
    }

    /// Substrings that mean "there's a call link in here". Kept broad rather
    /// than clever: a missed marker only costs the calendar trigger for that
    /// event, and the mic trigger still catches the meeting.
    private static let conferenceMarkers = [
        "zoom.us", "meet.google.com", "teams.microsoft", "teams.live", "whereby.com",
        "webex.com", "jitsi", "around.co", "gather.town", "huddle", "discord.gg",
        "telemost", "yandex.ru/telemost", "ktalk", "contour.ru", "salutejazz", "vkmeet",
    ]
}
