import Observation
import CoreLocation
import Foundation
import Darwin

@Observable
final class PATCOScheduleStore {
    private(set) var feed: PATCOFeed?
    private(set) var loadError: Error?
    private(set) var activeSpecialSchedule: ActiveSpecialSchedule?
    private(set) var feedMetadata: PATCOFeedMetadata?

    private var baseFeed: PATCOFeed?
    private var specialFeedsByDateKey: [String: PATCOFeed] = [:]
    private var specialSchedulesByDateKey: [String: ActiveSpecialSchedule] = [:]
    private var stationById: [String: Station] = [:]
    private var calendar = Calendar(identifier: .gregorian)

    init() {
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        load()
    }

    init(feed: PATCOFeed) {
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        do {
            try feed.validateStopIdentifiers()
        } catch {
            loadError = error
            return
        }
        baseFeed = feed
        self.feed = feed
        stationById = Dictionary(uniqueKeysWithValues: feed.stops.map { ($0.id, $0) })
    }

    func load() {
        do {
            let decoded: PATCOFeed
            if let cachedFeed = PATCOFeedCache.load() {
                decoded = cachedFeed
                feedMetadata = PATCOFeedCache.loadMetadata()
            } else {
                guard let url = Bundle.main.url(forResource: "patco_schedule", withExtension: "json") else {
                    throw ScheduleLoadError.missingResource
                }
                decoded = try PATCOFeedCache.decodeValidatedFeed(Data(contentsOf: url))
                feedMetadata = nil
            }
            stationById = Dictionary(uniqueKeysWithValues: decoded.stops.map { ($0.id, $0) })
            baseFeed = decoded
            feed = decoded
            loadError = nil
        } catch {
            loadError = error
        }
    }

    var stations: [Station] {
        feed?.stops ?? []
    }

    var baseScheduleFeed: PATCOFeed? {
        baseFeed
    }

    var scheduleFeedVersion: String? {
        baseFeed?.feed["feed_version"]
    }

    var scheduleFeedEndDate: Date? {
        baseFeed?.serviceEndDate
    }

    var scheduleFeedLastUpdatedAt: Date? {
        feedMetadata?.lastUpdatedAt
    }

    var scheduleFeedLastCheckedAt: Date? {
        feedMetadata?.downloadedAt
    }

    var scheduleFeedPreviousVersion: String? {
        feedMetadata?.previousFeedVersion
    }

    var ashland: Station? {
        stations.first { $0.name == "Ashland" }
    }

    var locust: Station? {
        stations.first { $0.name == "15/16th and Locust" }
    }

    func station(for id: Station.ID) -> Station? {
        stationById[id]
    }

    func departure(matching link: DepartureDeepLink) -> Departure? {
        guard let origin = station(for: link.originId), let destination = station(for: link.destinationId),
              origin.id != destination.id else { return nil }
        return departures(from: origin, to: destination, after: link.departureDate.addingTimeInterval(-60), limit: 6)
            .first { abs($0.departureDate.timeIntervalSince(link.departureDate)) < 60 }
    }

    func nearestStation(to location: CLLocation) -> Station? {
        stations.min { left, right in
            left.location.distance(from: location) < right.location.distance(from: location)
        }
    }

    func applySpecialSchedule(_ schedule: PATCOSpecialSchedule) {
        applySpecialSchedules([schedule])
    }

    func applySpecialSchedules(_ schedules: [PATCOSpecialSchedule]) {
        specialFeedsByDateKey = [:]
        specialSchedulesByDateKey = [:]

        for schedule in schedules {
            applySpecialScheduleFeed(schedule)
        }

        activeSpecialSchedule = specialSchedulesByDateKey.values.first {
            calendar.isDate($0.serviceDate, inSameDayAs: Date())
        }

        feed = activeSpecialSchedule.flatMap { specialFeedsByDateKey[Self.yyyymmddFormatter.string(from: $0.serviceDate)] } ?? baseFeed
    }

    private func applySpecialScheduleFeed(_ schedule: PATCOSpecialSchedule) {
        guard let baseFeed, !schedule.trips.isEmpty else { return }

        let ymd = Self.yyyymmddFormatter.string(from: schedule.serviceDate)
        let serviceId = "Special Schedule \(ymd)"
        let confirmedTrips = schedule.trips.filter { trip in
            trip.stopTimes.filter { !$0.isEmpty }.allSatisfy {
                Self.scheduleDate(serviceDate: schedule.serviceDate, timeString: $0, isSpecialSchedule: true) != nil
            }
        }
        let trips = confirmedTrips.enumerated().map { index, scheduledTrip in
            let stationOrder = scheduledTrip.directionId == 0 ? baseFeed.stops : Array(baseFeed.stops.reversed())

            return Trip(
                id: "\(serviceId) Trip \(index + 1)",
                serviceId: serviceId,
                headsign: scheduledTrip.directionId == 0 ? "Philadelphia" : "Lindenwold",
                directionId: scheduledTrip.directionId,
                bikesAllowed: true,
                wheelchairAccessible: true,
                stopTimes: scheduledTrip.stopTimes.enumerated().compactMap { stopIndex, time in
                    guard !time.isEmpty else { return nil }
                    return StopTime(
                        stopId: stationOrder[stopIndex].id,
                        arrival: time,
                        departure: time,
                        sequence: stopIndex + 1
                    )
                }
            )
        }

        let specialFeed = PATCOFeed(
            generatedFrom: schedule.sourceURL.absoluteString,
            feed: baseFeed.feed,
            route: baseFeed.route,
            stops: baseFeed.stops,
            calendars: [
                ServiceCalendar(
                    serviceId: serviceId,
                    weekdays: Weekdays(monday: false, tuesday: false, wednesday: false, thursday: false, friday: false, saturday: false, sunday: false),
                    startDate: ymd,
                    endDate: ymd
                )
            ],
            calendarDates: [
                CalendarDateException(serviceId: serviceId, date: ymd, exceptionType: 1)
            ],
            trips: trips
        )

        specialFeedsByDateKey[ymd] = specialFeed
        specialSchedulesByDateKey[ymd] = ActiveSpecialSchedule(title: schedule.title, serviceDate: schedule.serviceDate,
            sourceURL: schedule.sourceURL, tripCount: trips.count, hasUnconfirmedTimes: confirmedTrips.count != schedule.trips.count)
    }

    func clearSpecialSchedule() {
        specialFeedsByDateKey = [:]
        specialSchedulesByDateKey = [:]
        feed = baseFeed
        activeSpecialSchedule = nil
    }

    func specialSchedule(on date: Date) -> ActiveSpecialSchedule? {
        specialSchedulesByDateKey[Self.yyyymmddFormatter.string(from: date)]
    }

    func departures(
        from origin: Station,
        to destination: Station,
        after date: Date = Date(),
        limit: Int? = 10,
        includingRemovedSpecialScheduleDepartures: Bool = false
    ) -> [Departure] {
        guard let feed else { return [] }

        let standardDepartures = standardScheduleDepartures(from: origin, to: destination, after: date)
        var results: [Departure] = []
        for dayOffset in -1...1 {
            guard let serviceDate = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: date)) else {
                continue
            }

            let serviceFeed = feedForServiceDate(serviceDate) ?? feed
            let isSpecialSchedule = specialFeedsByDateKey[Self.yyyymmddFormatter.string(from: serviceDate)] != nil
            let activeServices = activeServiceIds(on: serviceDate, feed: serviceFeed)
            let dayResults = serviceFeed.trips.compactMap {
                departure(
                    for: $0,
                    origin: origin,
                    destination: destination,
                    serviceDate: serviceDate,
                    activeServices: activeServices,
                    isSpecialSchedule: isSpecialSchedule
                )
            }
                .filter { departure in
                    let departureDateKey = Self.yyyymmddFormatter.string(from: departure.departureDate)
                    if isSpecialSchedule {
                        // A following day's special schedule takes precedence over
                        // any after-midnight trips carried by this special feed.
                        return departureDateKey == Self.yyyymmddFormatter.string(from: serviceDate)
                            || specialFeedsByDateKey[departureDateKey] == nil
                    }

                    // Regular GTFS often carries early-morning trains as 24:xx on
                    // the prior service day. Do not show that version when a
                    // special timetable covers its actual calendar departure day.
                    return specialFeedsByDateKey[departureDateKey] == nil
                }
                .sorted { $0.departureDate < $1.departureDate }
            let standardDeparturesForServiceDate = specialSchedule(on: serviceDate)?.hasUnconfirmedTimes == true ? nil : standardDeparturesForSpecialSchedule(
                on: serviceDate,
                matching: dayResults,
                from: standardDepartures
            )
            let comparedDayResults = standardDeparturesForServiceDate.map {
                departuresWithScheduleAdjustments(
                    dayResults,
                    standardDepartures: $0,
                    includingRemovedSpecialScheduleDepartures: includingRemovedSpecialScheduleDepartures
                )
            } ?? dayResults

            results.append(contentsOf: comparedDayResults.filter { $0.departureDate >= date })
        }

        results.sort { $0.departureDate < $1.departureDate }
        if let limit {
            return Array(results.prefix(limit))
        }

        return results
    }

    private func feedForServiceDate(_ serviceDate: Date) -> PATCOFeed? {
        let dateKey = Self.yyyymmddFormatter.string(from: serviceDate)
        if let specialFeed = specialFeedsByDateKey[dateKey] {
            return specialFeed
        }

        return baseFeed
    }

    private func standardDeparturesForSpecialSchedule(
        on serviceDate: Date,
        matching specialDepartures: [Departure],
        from standardDepartures: [Departure]?
    ) -> [Departure]? {
        let dateKey = Self.yyyymmddFormatter.string(from: serviceDate)
        guard specialFeedsByDateKey[dateKey] != nil else {
            return nil
        }

        let departureDateKeys = Set(specialDepartures.map {
            Self.yyyymmddFormatter.string(from: $0.departureDate)
        })
        return standardDepartures?.filter {
            departureDateKeys.contains(Self.yyyymmddFormatter.string(from: $0.departureDate))
        }
    }

    private func standardScheduleDepartures(from origin: Station, to destination: Station, after date: Date) -> [Departure]? {
        guard !specialFeedsByDateKey.isEmpty, let baseFeed else { return nil }

        var departures: [Departure] = []
        for dayOffset in -1...1 {
            guard let serviceDate = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: date)) else {
                continue
            }

            let activeServices = activeServiceIds(on: serviceDate, feed: baseFeed)
            for trip in baseFeed.trips {
                guard let departure = departure(
                    for: trip,
                    origin: origin,
                    destination: destination,
                    serviceDate: serviceDate,
                    activeServices: activeServices
                ) else {
                    continue
                }

                departures.append(departure)
            }
        }

        return departures.sorted { $0.departureDate < $1.departureDate }
    }

    private func departure(
        for trip: Trip,
        origin: Station,
        destination: Station,
        serviceDate: Date,
        activeServices: Set<String>,
        isSpecialSchedule: Bool = false
    ) -> Departure? {
        guard activeServices.contains(trip.serviceId),
              let originTime = trip.stopTimes.first(where: { $0.stopId == origin.id }),
              let destinationTime = trip.stopTimes.first(where: { $0.stopId == destination.id }),
              originTime.sequence < destinationTime.sequence,
              let departureDate = Self.scheduleDate(serviceDate: serviceDate, timeString: originTime.departure,
                                                     isSpecialSchedule: isSpecialSchedule),
              let arrivalDate = Self.scheduleDate(serviceDate: serviceDate, timeString: destinationTime.arrival,
                                                   isSpecialSchedule: isSpecialSchedule) else {
            return nil
        }

        return Departure(
            trip: trip,
            origin: origin,
            destination: destination,
            originTime: originTime,
            destinationTime: destinationTime,
            serviceDate: serviceDate,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            routeSequenceIndex: 0,
            isSpecialSchedule: isSpecialSchedule,
            isRemovedBySpecialSchedule: false,
            scheduleAdjustment: nil
        )
    }

    private func departuresWithScheduleAdjustments(
        _ departures: [Departure],
        standardDepartures: [Departure],
        includingRemovedSpecialScheduleDepartures: Bool
    ) -> [Departure] {
        var unmatchedStandardIndices = Set(standardDepartures.indices)
        var adjustments = Array<ScheduleAdjustment?>(repeating: nil, count: departures.count)
        var unmatchedDepartureIndices: [Int] = []

        for (index, departure) in departures.enumerated() {
            let exactStandardIndices = unmatchedStandardIndices.filter {
                comparisonKey(for: standardDepartures[$0]) == comparisonKey(for: departure)
            }
            if !exactStandardIndices.isEmpty {
                // The GTFS can contain more than one service candidate for the
                // same physical departure. A special departure at that exact
                // time replaces the entire slot, not just one duplicate trip.
                exactStandardIndices.forEach { unmatchedStandardIndices.remove($0) }
            } else {
                unmatchedDepartureIndices.append(index)
            }
        }

        // Pair nearby departure times one-to-one. A special schedule can change
        // travel time substantially, so arrival time must not turn a shifted train
        // into a misleading added-and-removed pair.
        let candidates = unmatchedDepartureIndices.flatMap { departureIndex in
            unmatchedStandardIndices.compactMap { standardIndex -> (departure: Int, standard: Int, distance: TimeInterval)? in
                let departure = departures[departureIndex]
                let standard = standardDepartures[standardIndex]
                let departureDistance = abs(departure.departureDate.timeIntervalSince(standard.departureDate))
                guard departureDistance <= 15 * 60 else { return nil }
                return (departureIndex, standardIndex, departureDistance)
            }
        }.sorted { $0.distance < $1.distance }

        var matchedDepartureIndices: Set<Int> = []
        for candidate in candidates where !matchedDepartureIndices.contains(candidate.departure) && unmatchedStandardIndices.contains(candidate.standard) {
            matchedDepartureIndices.insert(candidate.departure)
            let originalDepartureKey = comparisonKey(for: standardDepartures[candidate.standard])
            // One regular departure can have duplicate GTFS service candidates.
            // Once a special train is identified as its adjustment, none of those
            // same-time candidates should also render as canceled.
            unmatchedStandardIndices
                .filter { comparisonKey(for: standardDepartures[$0]) == originalDepartureKey }
                .forEach { unmatchedStandardIndices.remove($0) }
            adjustments[candidate.departure] = ScheduleAdjustment(
                originalDepartureDate: standardDepartures[candidate.standard].departureDate
            )
        }

        for index in unmatchedDepartureIndices where !matchedDepartureIndices.contains(index) {
            adjustments[index] = ScheduleAdjustment(originalDepartureDate: nil)
        }

        var comparedDepartures = departures.enumerated().map { index, departure in
            departure.withScheduleAdjustment(adjustments[index], routeSequenceIndex: index)
        }

        if includingRemovedSpecialScheduleDepartures {
            // GTFS service calendars can yield multiple candidates for the same
            // physical departure. The comparison key already treats that minute
            // as one schedule slot, so render one canceled row for that slot.
            var removedStandardIndexByDepartureKey: [Int: Int] = [:]
            for standardIndex in unmatchedStandardIndices {
                let key = comparisonKey(for: standardDepartures[standardIndex])
                if removedStandardIndexByDepartureKey[key] == nil {
                    removedStandardIndexByDepartureKey[key] = standardIndex
                }
            }
            comparedDepartures.append(contentsOf: removedStandardIndexByDepartureKey.values.map {
                standardDepartures[$0].markedRemovedBySpecialSchedule(routeSequenceIndex: 0)
            })
        }

        return comparedDepartures
            .sorted { $0.departureDate < $1.departureDate }
            .enumerated()
            .map { index, departure in
                departure.withScheduleAdjustment(departure.scheduleAdjustment, routeSequenceIndex: index)
            }
    }

    private func comparisonKey(for departure: Departure) -> Int {
        Int(departure.departureDate.timeIntervalSince1970 / 60)
    }

    private func activeServiceIds(on date: Date, feed: PATCOFeed) -> Set<String> {
        let ymd = Self.yyyymmddFormatter.string(from: date)
        let weekday = calendar.component(.weekday, from: date)

        var active = Set(feed.calendars.filter { service in
            service.startDate <= ymd && service.endDate >= ymd && service.weekdays.contains(weekday)
        }.map(\.serviceId))

        for exception in feed.calendarDates where exception.date == ymd {
            if exception.exceptionType == 1 {
                active.insert(exception.serviceId)
            } else if exception.exceptionType == 2 {
                active.remove(exception.serviceId)
            }
        }

        return active
    }

    static func scheduleDate(serviceDate: Date, timeString: String, isSpecialSchedule: Bool = false) -> Date? {
        let calendar = PATCOClock.calendar
        let pieces = timeString.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 3, let hours = Int(pieces[0]), let minutes = Int(pieces[1]), let seconds = Int(pieces[2]),
              hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }

        if isSpecialSchedule {
            // PDF values are clock times, not GTFS elapsed service-day offsets.
            guard let day = calendar.date(byAdding: .day, value: hours / 24, to: calendar.startOfDay(for: serviceDate)),
                  let result = calendar.date(bySettingHour: hours % 24, minute: minutes, second: seconds,
                                             of: day, matchingPolicy: .strict, repeatedTimePolicy: .first),
                  calendar.isDate(result, inSameDayAs: day), !PATCOClock.isRepeatedTime(result) else { return nil }
            return result
        }

        // GTFS measures elapsed seconds from local noon minus twelve hours.
        // Using midnight or setting wall-clock components shifts DST-night trains.
        guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: serviceDate) else { return nil }
        return noon.addingTimeInterval(Double(hours) * 3600 + Double(minutes * 60 + seconds) - 12 * 3600)
    }

    static let yyyymmddFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}
