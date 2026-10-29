#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct MidnightScheduleCheck {
    static func run() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for parts in [DateComponents(year: 2026, month: 10, day: 15, hour: 23, minute: 20),
                      DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 20),
                      DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 20)] {
            let now = calendar.date(from: parts)!
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let departure = midnight.addingTimeInterval(4 * 3600 + 32 * 60)
            let timeline = WidgetTimelinePolicy.entryDates(now: now, departures: [departure])
            XCTAssertTrue(timeline.contains(midnight), "Both widget families must update at Eastern midnight, including DST days")
            XCTAssertTrue(WidgetDepartureDay.label(for: departure, relativeTo: midnight, timeZone: calendar.timeZone) == nil)
        }

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
        XCTAssertTrue(beforeMidnight.first?.departureDate == date(23, 0, 6))

        let departures = store.departures(from: origin, to: destination, after: afterMidnight, limit: 2)
        XCTAssertTrue(departures.map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12)])
        XCTAssertTrue(calendar.isDate(departures[0].serviceDate, inSameDayAs: date(22, 12, 0)))
        XCTAssertTrue(departures.allSatisfy { !$0.isSpecialSchedule })

        let tripDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tripDirectory) }
        let tripRoute = SharedRouteCoordinator.commit(originId: origin.id, destinationId: destination.id,
                                                     now: afterMidnight, directory: tripDirectory)!
        func location(_ age: Double, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: origin.coordinate, altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: -1, timestamp: afterMidnight.addingTimeInterval(age))
        }
        let firstState = SharedTripState.update(store: store, routeRevision: tripRoute.revision,
                           location: location(0), now: afterMidnight, directory: tripDirectory,
                           specialSchedules: [])!
        XCTAssertTrue(firstState.shouldReloadWidgets)
        let decodedState = SharedTripState.current(directory: tripDirectory)!
        XCTAssertTrue(decodedState.departures.map(\.id) == firstState.snapshot.departures.map(\.id))
        XCTAssertTrue(decodedState.upcoming(at: afterMidnight).map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12), date(23, 0, 20)])
        XCTAssertTrue(decodedState.catchResult(for: decodedState.departures[0], at: afterMidnight)?.status == .atStation)
        func travelState(minutes: Int) -> SharedTripState.Snapshot {
            .init(schema: 1, routeRevision: tripRoute.revision, origin: origin, destination: destination,
                  preparedAt: afterMidnight, departures: decodedState.departures, scheduleVersion: nil,
                  scheduleExpired: false, scheduleExpiresAt: afterMidnight.addingTimeInterval(3600), specialSchedules: [],
                  guidance: .init(location: .init(latitude: 39.01, longitude: -75, horizontalAccuracy: 10,
                                                  timestamp: afterMidnight), mode: .driving,
                                  travelMinutes: minutes, estimateSource: "Maps estimate", estimateFetchedAt: afterMidnight),
                  lastBroadcastAt: afterMidnight)
        }
        let guidanceState = travelState(minutes: 2)
        XCTAssertTrue(guidanceState.catchResult(for: decodedState.departures[1], at: afterMidnight)?.status == .comfortable)
        XCTAssertTrue(guidanceState.catchResult(for: decodedState.departures[0], at: afterMidnight)?.status == .tight)
        XCTAssertTrue(guidanceState.catchResult(for: decodedState.departures[0], at: afterMidnight.addingTimeInterval(60))?.status == .probablyMissed)
        XCTAssertTrue(travelState(minutes: 10).catchResult(for: decodedState.departures[0], at: afterMidnight)?.status == .tooLate)
        XCTAssertTrue(guidanceState.isScheduleExpired(at: afterMidnight.addingTimeInterval(3600)))
        let delayedState = SharedTripState.update(store: store, routeRevision: tripRoute.revision,
                         location: location(-10), now: afterMidnight.addingTimeInterval(10),
                         directory: tripDirectory, specialSchedules: [])!
        XCTAssertTrue(delayedState.snapshot.guidance?.location.timestamp == afterMidnight)
        XCTAssertTrue(!delayedState.shouldReloadWidgets)
        XCTAssertTrue(delayedState.snapshot.departures.map(\.id) == decodedState.departures.map(\.id))
        let olderWrite = SharedTripState.update(store: store, routeRevision: tripRoute.revision,
                         location: location(-20), now: afterMidnight.addingTimeInterval(5),
                         directory: tripDirectory, specialSchedules: [])!
        XCTAssertTrue(olderWrite.snapshot.preparedAt == delayedState.snapshot.preparedAt)
        let failed = SharedTripState.update(store: store, routeRevision: tripRoute.revision,
                         location: location(15, accuracy: 1400), now: afterMidnight.addingTimeInterval(15),
                         directory: tripDirectory, specialSchedules: [])!
        XCTAssertTrue(failed.snapshot.guidance?.location.timestamp == afterMidnight)
        XCTAssertTrue(failed.snapshot.catchResult(for: failed.snapshot.departures[0], at: afterMidnight.addingTimeInterval(181)) == nil)
        let revoked = SharedTripState.update(store: store, routeRevision: tripRoute.revision,
                         location: location(20), locationAllowed: false, now: afterMidnight.addingTimeInterval(20),
                         directory: tripDirectory, specialSchedules: [])!
        XCTAssertTrue(revoked.snapshot.guidance == nil)
        let reversedTripRoute = SharedRouteCoordinator.reverse(expectedRevision: tripRoute.revision,
                                                  now: afterMidnight.addingTimeInterval(21), directory: tripDirectory)!
        XCTAssertTrue(SharedTripState.current(directory: tripDirectory) == nil)
        XCTAssertTrue(SharedTripState.update(store: store, routeRevision: tripRoute.revision, location: location(22),
                         now: afterMidnight.addingTimeInterval(22), directory: tripDirectory, specialSchedules: []) == nil)
        let returnState = SharedTripState.update(store: store, routeRevision: reversedTripRoute.revision,
                         location: nil, now: afterMidnight.addingTimeInterval(23), directory: tripDirectory, specialSchedules: [])!
        XCTAssertTrue(returnState.snapshot.origin.id == destination.id && returnState.snapshot.destination.id == origin.id)
        XCTAssertTrue(returnState.shouldReloadWidgets)

        let routeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: routeDirectory) }
        let savedRoute = SharedRouteCoordinator.commit(originId: destination.id, destinationId: origin.id,
                                                       manual: true, directory: routeDirectory)!
        let linkURL = URL(string: "patconext://departure?origin=1&destination=2&departure=\(date(23, 0, 6).timeIntervalSince1970)")!
        let link = DepartureDeepLink(url: linkURL)!
        let linkedDeparture = store.departure(matching: link)!
        XCTAssertTrue(linkedDeparture.origin.id == origin.id && linkedDeparture.destination.id == destination.id)
        XCTAssertTrue(linkedDeparture.departureDate == date(23, 0, 6))
        XCTAssertTrue(SharedRouteCoordinator.current(directory: routeDirectory) == savedRoute)
        XCTAssertTrue(SharedRouteCoordinator.selectedStations(in: store.stations, directory: routeDirectory)?.origin.id == destination.id)
        XCTAssertTrue(DepartureDeepLink(url: URL(string: "patconext://departure?origin=1&destination=2&departure=nan")!) == nil)
        XCTAssertTrue(DepartureDeepLink(url: URL(string: "patconext://departure?origin=1&destination=1&departure=1")!) == nil)
        let missingStation = DepartureDeepLink(url: URL(string: "patconext://departure?origin=unknown&destination=2&departure=1")!)!
        XCTAssertTrue(store.departure(matching: missingStation) == nil)

        let special = PATCOSpecialSchedule(
            title: "Tuesday special",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/special.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:08:00", "24:28:00"])]
        )
        store.applySpecialSchedules([special])
        let specialRoute = SharedRouteCoordinator.commit(originId: origin.id, destinationId: destination.id,
                                    manual: true, now: afterMidnight.addingTimeInterval(24), directory: tripDirectory)!
        let specialState = SharedTripState.update(store: store, routeRevision: specialRoute.revision,
                                    location: nil, now: afterMidnight.addingTimeInterval(25),
                                    directory: tripDirectory, specialSchedules: [special])!
        XCTAssertTrue(specialState.snapshot.upcoming(at: afterMidnight).first?.departureDate == date(23, 0, 8))
        let decodedSpecial = SharedTripState.current(directory: tripDirectory)!
        XCTAssertTrue(decodedSpecial.departures.first?.isSpecialSchedule == true)
        XCTAssertTrue(decodedSpecial.departures.first?.scheduleAdjustment?.originalDepartureDate == date(23, 0, 6))
        XCTAssertTrue(decodedSpecial.departures.allSatisfy { !$0.isRemovedBySpecialSchedule })
        let specialDepartures = store.departures(from: origin, to: destination, after: afterMidnight, limit: 2)
        XCTAssertTrue(specialDepartures.map(\.departureDate) == [date(23, 0, 8), date(23, 0, 12)])
        XCTAssertTrue(specialDepartures[0].isSpecialSchedule)
        XCTAssertTrue(!specialDepartures[1].isSpecialSchedule)
        XCTAssertTrue(specialDepartures[0].deviatesFromStandardSchedule)
        XCTAssertTrue(specialDepartures[0].scheduleAdjustment?.originalDepartureDate == date(23, 0, 6))
        XCTAssertTrue(store.specialSchedule(on: specialDepartures[0].serviceDate)?.title == "Tuesday special")
        let specialLink = DepartureDeepLink(url: URL(string: "patconext://departure?origin=1&destination=2&departure=\(date(23, 0, 8).timeIntervalSince1970)")!)!
        XCTAssertTrue(store.departure(matching: specialLink)?.isSpecialSchedule == true)
        XCTAssertTrue(SharedRouteCoordinator.current(directory: routeDirectory) == savedRoute)

        let specialDeparturesIncludingRemoved = store.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        let removedSpecialDepartures = specialDeparturesIncludingRemoved.filter(\.isRemovedBySpecialSchedule)
        XCTAssertTrue(removedSpecialDepartures.contains { $0.departureDate == date(23, 0, 20) })
        XCTAssertTrue(!removedSpecialDepartures.contains { $0.departureDate == date(23, 0, 6) })

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
        XCTAssertTrue(slowSpecialDepartures.first?.scheduleAdjustment?.originalDepartureDate == date(23, 0, 6))
        XCTAssertTrue(!slowSpecialDepartures.contains { $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 6) })
        XCTAssertTrue(slowSpecialDepartures.contains { $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 20) })

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
        XCTAssertTrue(calendarDayDepartures.map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12), date(23, 0, 20)])
        XCTAssertTrue(!calendarDayDepartures[0].isRemovedBySpecialSchedule)
        XCTAssertTrue(calendarDayDepartures[1].isRemovedBySpecialSchedule)
        XCTAssertTrue(calendarDayDepartures[2].isRemovedBySpecialSchedule)

        let unchangedSpecial = PATCOSpecialSchedule(
            title: "Tuesday published schedule",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/published.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:06:00", "24:26:00"])]
        )
        store.applySpecialSchedules([unchangedSpecial])
        let unchangedDeparture = store.departures(from: origin, to: destination, after: afterMidnight, limit: 1).first!
        XCTAssertTrue(unchangedDeparture.isSpecialSchedule)
        XCTAssertTrue(unchangedDeparture.scheduleAdjustment == nil)

        let arrivalOnlySpecial = PATCOSpecialSchedule(
            title: "Tuesday arrival change",
            serviceDate: date(22, 12, 0),
            sourceURL: URL(string: "https://example.com/arrival.pdf")!,
            trips: [.init(directionId: 0, stopTimes: ["24:06:00", "24:27:00"])]
        )
        store.applySpecialSchedules([arrivalOnlySpecial])
        let arrivalOnlyDeparture = store.departures(from: origin, to: destination, after: afterMidnight, limit: 1).first!
        XCTAssertTrue(arrivalOnlyDeparture.scheduleAdjustment == nil)

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
        XCTAssertTrue(mixedDepartures.map(\.departureDate) == [date(23, 0, 6), date(23, 0, 12), date(23, 0, 22), date(23, 0, 45)])
        XCTAssertTrue(mixedDepartures[0].scheduleAdjustment == nil)
        XCTAssertTrue(mixedDepartures[2].scheduleAdjustment?.originalDepartureDate == date(23, 0, 20))
        XCTAssertTrue(mixedDepartures[3].deviatesFromStandardSchedule)
        XCTAssertTrue(mixedDepartures[3].scheduleAdjustment?.originalDepartureDate == nil)

        let mixedDeparturesIncludingRemoved = store.departures(
            from: origin,
            to: destination,
            after: afterMidnight,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
        )
        XCTAssertTrue(!mixedDeparturesIncludingRemoved.contains {
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
        XCTAssertTrue(adjustedDepartures.contains {
            $0.departureDate == date(23, 0, 8) && $0.scheduleAdjustment?.originalDepartureDate == date(23, 0, 6)
        })
        XCTAssertTrue(!adjustedDepartures.contains {
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
        XCTAssertTrue(
            duplicateRemovedDepartures.filter {
                $0.isRemovedBySpecialSchedule && $0.departureDate == date(23, 0, 20)
            }.count == 1,
            "Duplicate canceled departures should collapse into one row"
        )

        store.applySpecialSchedules([special])
        let delayed = store.departures(from: origin, to: destination, after: date(23, 0, 7), limit: nil)
        XCTAssertTrue(delayed.first?.departureDate == date(23, 0, 8))
        XCTAssertTrue(delayed.first?.scheduleAdjustment?.originalDepartureDate == date(23, 0, 6),
                     "A delayed departure must retain its original time after that time passes")

        for (month, day) in [(3, 8), (11, 1)] {
            let serviceDay = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let dayKey = PATCOScheduleStore.yyyymmddFormatter.string(from: serviceDay)
            let dstFeed = PATCOFeed(
                generatedFrom: "dst-check", feed: [:], route: [:], stops: [origin, destination],
                calendars: [],
                calendarDates: [CalendarDateException(serviceId: "DST", date: dayKey, exceptionType: 1)],
                trips: [trip("morning", service: "DST", departure: "08:00:00", arrival: "08:26:00"),
                        trip("overnight", service: "DST", departure: "24:06:00", arrival: "24:26:00")]
            )
            let dstDepartures = PATCOScheduleStore(feed: dstFeed).departures(from: origin, to: destination, after: serviceDay, limit: nil)
            XCTAssertTrue(dstDepartures.count == 2)
            XCTAssertTrue(calendar.component(.hour, from: dstDepartures[0].departureDate) == 8)
            XCTAssertTrue(calendar.component(.minute, from: dstDepartures[0].arrivalDate) == 26)
            XCTAssertTrue(calendar.component(.hour, from: dstDepartures[1].departureDate) == 0)
            XCTAssertTrue(calendar.component(.day, from: dstDepartures[1].departureDate) == day + 1)
        }

        print("Midnight schedule checks passed")
    }
}
