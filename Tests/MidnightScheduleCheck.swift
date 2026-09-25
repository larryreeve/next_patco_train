import Foundation

@main
struct MidnightScheduleCheck {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }

        let origin = Station(id: "1", code: "A", name: "Ashland", latitude: 39.0, longitude: -75.0, zone: "1", url: "")
        let destination = Station(id: "2", code: "B", name: "Broadway", latitude: 39.1, longitude: -75.1, zone: "1", url: "")
        let noWeekdays = Weekdays(monday: false, tuesday: false, wednesday: false, thursday: false, friday: false, saturday: false, sunday: false)

        func trip(_ id: String, service: String, departure: String, arrival: String) -> Trip {
            Trip(
                id: id,
                serviceId: service,
                headsign: "Philadelphia",
                directionId: 0,
                bikesAllowed: true,
                wheelchairAccessible: true,
                stopTimes: [
                    StopTime(stopId: origin.id, arrival: departure, departure: departure, sequence: 1),
                    StopTime(stopId: destination.id, arrival: arrival, departure: arrival, sequence: 2)
                ]
            )
        }

        let feed = PATCOFeed(
            generatedFrom: "midnight-check",
            feed: [:],
            route: [:],
            stops: [origin, destination],
            calendars: [
                ServiceCalendar(serviceId: "Tuesday", weekdays: noWeekdays, startDate: "20260922", endDate: "20260922"),
                ServiceCalendar(serviceId: "Wednesday", weekdays: noWeekdays, startDate: "20260923", endDate: "20260923")
            ],
            calendarDates: [
                CalendarDateException(serviceId: "Tuesday", date: "20260922", exceptionType: 1),
                CalendarDateException(serviceId: "Wednesday", date: "20260923", exceptionType: 1)
            ],
            trips: [
                trip("tuesday-early", service: "Tuesday", departure: "24:06:00", arrival: "24:26:00"),
                trip("tuesday-late", service: "Tuesday", departure: "24:20:00", arrival: "24:40:00"),
                trip("wednesday", service: "Wednesday", departure: "00:12:00", arrival: "00:32:00")
            ]
        )
        let store = PATCOScheduleStore(feed: feed)
        let afterMidnight = date(23, 0, 1)

        let beforeMidnight = store.departures(from: origin, to: destination, after: date(22, 23, 59), limit: 1)
        precondition(beforeMidnight.first?.departureDate == date(23, 0, 6))

        let departures = store.departures(from: origin, to: destination, after: afterMidnight, limit: 2)
        precondition(departures.map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12)])
        precondition(calendar.isDate(departures[0].serviceDate, inSameDayAs: date(22, 12, 0)))
        precondition(departures.allSatisfy { !$0.isSpecialSchedule })

        let special = PATCOSpecialSchedule(
            title: "Tuesday special",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/special.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:08:00", "24:28:00"])]
        )
        store.applySpecialSchedules([special])
        let specialDepartures = store.departures(from: origin, to: destination, after: afterMidnight, limit: 2)
        precondition(specialDepartures.map(\.departureDate) == [date(23, 0, 8), date(23, 0, 12)])
        precondition(specialDepartures[0].isSpecialSchedule)
        precondition(!specialDepartures[1].isSpecialSchedule)
        precondition(specialDepartures[0].deviatesFromStandardSchedule)
        precondition(specialDepartures[0].scheduleAdjustment?.originalDepartureDate == date(23, 0, 6))
        precondition(store.specialSchedule(on: specialDepartures[0].serviceDate)?.title == "Tuesday special")

        let specialDeparturesIncludingRemoved = store.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        let removedSpecialDepartures = specialDeparturesIncludingRemoved.filter(\.isRemovedBySpecialSchedule)
        precondition(removedSpecialDepartures.contains { $0.departureDate == date(23, 0, 20) })
        precondition(!removedSpecialDepartures.contains { $0.departureDate == date(23, 0, 6) })

        let slowSpecial = PATCOSpecialSchedule(
            title: "Tuesday longer trip",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/longer-trip.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:08:00", "24:50:00"])]
        )
        store.applySpecialSchedules([slowSpecial])
        let slowSpecialDepartures = store.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        precondition(slowSpecialDepartures.first?.scheduleAdjustment?.originalDepartureDate == date(23, 0, 6))
        precondition(!slowSpecialDepartures.contains { $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 6) })
        precondition(slowSpecialDepartures.contains { $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 20) })

        // Regular GTFS represents 12:06 AM as 24:06 on the prior service day,
        // while a Saturday-style PDF represents it as 12:06 AM on the calendar day.
        // The special timetable must replace that physical departure, not duplicate it.
        let calendarDaySpecial = PATCOSpecialSchedule(
            title: "Wednesday calendar-day schedule",
            serviceDate: date(23, 12, 0),
            sourceURL: URL(string: "https://example.com/calendar-day.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["00:06:00", "00:26:00"])]
        )
        store.applySpecialSchedules([calendarDaySpecial])
        let calendarDayDepartures = store.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        precondition(calendarDayDepartures.map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12), date(23, 0, 20)])
        precondition(!calendarDayDepartures[0].isRemovedBySpecialSchedule)
        precondition(calendarDayDepartures[1].isRemovedBySpecialSchedule)
        precondition(calendarDayDepartures[2].isRemovedBySpecialSchedule)

        let unchangedSpecial = PATCOSpecialSchedule(
            title: "Tuesday published schedule",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/published.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:06:00", "24:26:00"])]
        )
        store.applySpecialSchedules([unchangedSpecial])
        let unchangedDeparture = store.departures(from: origin, to: destination, after: afterMidnight, limit: 1).first!
        precondition(unchangedDeparture.isSpecialSchedule)
        precondition(unchangedDeparture.scheduleAdjustment == nil)

        let arrivalOnlySpecial = PATCOSpecialSchedule(
            title: "Tuesday arrival change",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/arrival.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:06:00", "24:27:00"])]
        )
        store.applySpecialSchedules([arrivalOnlySpecial])
        let arrivalOnlyDeparture = store.departures(from: origin, to: destination, after: afterMidnight, limit: 1).first!
        precondition(arrivalOnlyDeparture.scheduleAdjustment == nil)

        let mixedSpecial = PATCOSpecialSchedule(
            title: "Tuesday mixed schedule",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/mixed.pdf")!,
            trips: [
                .init(directionId: 0, stopTimes: ["24:06:00", "24:26:00"]),
                .init(directionId: 0, stopTimes: ["24:22:00", "24:42:00"]),
                .init(directionId: 0, stopTimes: ["24:45:00", "25:05:00"])
            ]
        )
        store.applySpecialSchedules([mixedSpecial])
        let mixedDepartures = store.departures(from: origin, to: destination, after: afterMidnight, limit: 4)
        precondition(mixedDepartures.map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12), date(23, 0, 22), date(23, 0, 45)])
        precondition(mixedDepartures[0].scheduleAdjustment == nil)
        precondition(mixedDepartures[2].scheduleAdjustment?.originalDepartureDate == date(23, 0, 20))
        precondition(mixedDepartures[3].deviatesFromStandardSchedule)
        precondition(mixedDepartures[3].scheduleAdjustment?.originalDepartureDate == nil)

        let mixedDeparturesIncludingRemoved = store.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        precondition(!mixedDeparturesIncludingRemoved.contains {
            $0.isRemovedBySpecialSchedule
                && [date(23, 0, 6), date(23, 0, 20), date(23, 0, 22), date(23, 0, 45)].contains($0.departureDate)
        })

        let duplicateCandidateFeed = PATCOFeed(
            generatedFrom: feed.generatedFrom,
            feed: feed.feed,
            route: feed.route,
            stops: feed.stops,
            calendars: feed.calendars,
            calendarDates: feed.calendarDates,
            trips: feed.trips + [trip("tuesday-early-duplicate", service: "Tuesday", departure: "24:06:00", arrival: "24:26:00")]
        )
        let duplicateCandidateStore = PATCOScheduleStore(feed: duplicateCandidateFeed)
        duplicateCandidateStore.applySpecialSchedules([special])
        let adjustedDepartures = duplicateCandidateStore.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        precondition(adjustedDepartures.contains {
            $0.departureDate == date(23, 0, 8) && $0.scheduleAdjustment?.originalDepartureDate == date(23, 0, 6)
        })
        precondition(!adjustedDepartures.contains {
            $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 6)
        })

        let duplicateRemovedCandidateFeed = PATCOFeed(
            generatedFrom: feed.generatedFrom,
            feed: feed.feed,
            route: feed.route,
            stops: feed.stops,
            calendars: feed.calendars,
            calendarDates: feed.calendarDates,
            trips: feed.trips + [trip("tuesday-late-duplicate", service: "Tuesday", departure: "24:20:00", arrival: "24:40:00")]
        )
        let duplicateRemovedCandidateStore = PATCOScheduleStore(feed: duplicateRemovedCandidateFeed)
        duplicateRemovedCandidateStore.applySpecialSchedules([special])
        let duplicateRemovedDepartures = duplicateRemovedCandidateStore.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        precondition(
            duplicateRemovedDepartures.filter {
                $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 20)
            }.count == 1,
            "Duplicate canceled departures should collapse into one row"
        )

        print("Midnight schedule checks passed")
    }
}
