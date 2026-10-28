import Foundation

@main
struct DSTScheduleCheck {
    static func main() throws {
        let calendar = PATCOClock.calendar
        let iso = ISO8601DateFormatter()
        func instant(_ text: String) -> Date { iso.date(from: text)! }
        func day(_ month: Int, _ date: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: date))!
        }
        let cases: [(Date, String, String)] = [
            (day(11, 1), "01:30:00", "2026-11-01T06:30:00Z"),
            (day(3, 8), "02:10:00", "2026-03-08T06:10:00Z"),
            (day(3, 8), "02:50:00", "2026-03-08T06:50:00Z"),
            (day(3, 7), "27:10:00", "2026-03-08T08:10:00Z"),
            (day(10, 31), "26:10:00", "2026-11-01T06:10:00Z"),
            (day(3, 8), "08:00:00", "2026-03-08T12:00:00Z"),
            (day(11, 1), "08:00:00", "2026-11-01T13:00:00Z"),
            (day(3, 8), "24:06:00", "2026-03-09T04:06:00Z"),
            (day(11, 1), "24:06:00", "2026-11-02T05:06:00Z")
        ]
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        for zone in ["America/New_York", "America/Los_Angeles", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for (serviceDay, time, expected) in cases {
                precondition(PATCOScheduleStore.scheduleDate(serviceDate: serviceDay, timeString: time) == instant(expected),
                             "GTFS conversion must preserve the absolute instant regardless of device zone")
            }
        }
        precondition(PATCOScheduleStore.scheduleDate(serviceDate: day(11, 1), timeString: "01:30:00",
            isSpecialSchedule: true) == nil, "An ambiguous PDF time must not silently select EDT or EST")
        precondition(PATCOClock.timeText(instant("2026-11-01T05:30:00Z"), locale: Locale(identifier: "en_US")).hasSuffix(" EDT"))
        precondition(PATCOClock.timeText(instant("2026-11-01T06:30:00Z"), locale: Locale(identifier: "en_US")).hasSuffix(" EST"))
        precondition(!PATCOClock.needsTimeZone(instant("2026-11-01T13:00:00Z")))
        precondition(PATCOClock.timeText(instant("2026-03-08T07:10:00Z"),
            relativeTo: instant("2026-03-08T06:50:00Z")).hasSuffix(" EDT"))
        precondition(PATCOScheduleStore.scheduleDate(serviceDate: day(3, 7), timeString: "27:10:00",
            isSpecialSchedule: true) == instant("2026-03-08T07:10:00Z"))
        for time in ["02:10:00", "02:50:00"] {
            precondition(PATCOScheduleStore.scheduleDate(serviceDate: day(3, 8), timeString: time,
                isSpecialSchedule: true) == nil, "Missing PDF clock times cannot silently become 3 AM")
        }
        for time in ["-1:00:00", "01:60:00", "01::00", "1:no:02:03"] {
            precondition(PATCOScheduleStore.scheduleDate(serviceDate: day(3, 8), timeString: time) == nil)
        }

        let origin = Station(id: "1", code: "A", name: "Origin", latitude: 39, longitude: -75, zone: "1", url: "")
        let destination = Station(id: "2", code: "B", name: "Destination", latitude: 39.1, longitude: -75, zone: "1", url: "")
        func store(serviceDay: Date, times: [(String, String)]) -> PATCOScheduleStore {
            PATCOScheduleStore(feed: PATCOFeed(generatedFrom: "dst-regression", feed: [:], route: [:],
                stops: [origin, destination], calendars: [],
                calendarDates: [.init(serviceId: "DST", date: PATCOScheduleStore.yyyymmddFormatter.string(from: serviceDay), exceptionType: 1)],
                trips: times.enumerated().map { index, times in
                    Trip(id: "trip-\(index)", serviceId: "DST", headsign: "Destination", directionId: 0,
                         bikesAllowed: true, wheelchairAccessible: true,
                         stopTimes: [.init(stopId: origin.id, arrival: times.0, departure: times.0, sequence: 1),
                                     .init(stopId: destination.id, arrival: times.1, departure: times.1, sequence: 2)])
                }))
        }
        let spring = store(serviceDay: day(3, 8), times: [("02:10:00", "02:30:00"), ("02:50:00", "03:10:00")])
        let springDepartures = spring.departures(from: origin, to: destination, after: instant("2026-03-08T05:00:00Z"), limit: nil)
        precondition(springDepartures.map(\.departureDate) == [instant("2026-03-08T06:10:00Z"), instant("2026-03-08T06:50:00Z")])
        precondition(springDepartures.allSatisfy { $0.arrivalDate.timeIntervalSince($0.departureDate) == 1200 })
        let fall = store(serviceDay: day(11, 1), times: [("00:50:00", "01:10:00"), ("01:30:00", "01:50:00")])
        let fallDepartures = fall.departures(from: origin, to: destination, after: instant("2026-11-01T05:45:00Z"), limit: nil)
        precondition(fallDepartures.map(\.departureDate) == [instant("2026-11-01T05:50:00Z"), instant("2026-11-01T06:30:00Z")])
        precondition(fallDepartures.allSatisfy { $0.arrivalDate.timeIntervalSince($0.departureDate) == 1200 })
        precondition(fall.departures(from: origin, to: destination, after: instant("2026-11-01T06:00:00Z"), limit: nil).count == 1,
                     "The second 1:30 AM must remain upcoming after the first 1:30 AM passes")
        fall.applySpecialSchedules([.init(title: "PDF", serviceDate: day(11, 1),
            sourceURL: URL(string: "https://example.com/schedule.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["01:30:00", "01:50:00"]),
                    .init(directionId: 0, stopTimes: ["03:30:00", "03:50:00"])])])
        let pdfDepartures = fall.departures(from: origin, to: destination, after: day(11, 1), limit: nil,
                                           includingRemovedSpecialScheduleDepartures: true)
        precondition(pdfDepartures.count == 1 && pdfDepartures[0].isSpecialSchedule)
        precondition(pdfDepartures[0].departureDate == instant("2026-11-01T08:30:00Z"))
        precondition(fall.specialSchedule(on: day(11, 1))?.hasUnconfirmedTimes == true)
        precondition(!pdfDepartures[0].isRemovedBySpecialSchedule, "Unconfirmed must not be presented as cancelled")
        let overnightPDF = PATCOSpecialSchedule(title: "Overnight PDF", serviceDate: day(10, 31),
            sourceURL: URL(string: "https://example.com/schedule.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["25:30:00", "26:30:00"])])
        let memoDates = (0..<60).map { day(10, 31).addingTimeInterval(Double($0 * 1800)) }
        let cachedWarnings = WidgetTimelinePolicy.unconfirmedTimesByDay(schedules: [overnightPDF], dates: memoDates)
        precondition(cachedWarnings.count == Set(memoDates.map { PATCOClock.calendar.startOfDay(for: $0) }).count)
        for date in memoDates {
            precondition(cachedWarnings[PATCOClock.calendar.startOfDay(for: date)] == overnightPDF.hasUnconfirmedTimes(on: date))
        }
        let widget = try String(contentsOfFile: "NextPATCOTrainWidget/NextPATCOTrainWidget.swift", encoding: .utf8)
        precondition(widget.contains("DST times unconfirmed; check PDF"))
        precondition(widget.contains("formatter.string(from: date) + PATCOClock.timeZoneSuffix(date)"))
        let detail = try String(contentsOfFile: "NextPATCOTrain/DepartureDetailView.swift", encoding: .utf8)
        precondition(detail.contains("isSpecialSchedule: departure.isSpecialSchedule"))
        precondition(detail.contains("isSpecialSchedule: isSpecialSchedule)"))
        precondition(detail.contains("scheduledStops.compactMap"))
        precondition(!detail.contains("?? serviceDate"), "Invalid PDF stop times must not become midnight Live Activity events")
        print("DST schedule checks passed: transition hours, overnight service, duration, PDF separation, device zones and Live Activity wiring")
    }
}
