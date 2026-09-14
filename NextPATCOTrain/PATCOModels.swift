import Combine
import CoreLocation
import Foundation

struct PATCOFeed: Codable {
    let generatedFrom: String
    let feed: [String: String]
    let route: [String: String]
    let stops: [Station]
    let calendars: [ServiceCalendar]
    let calendarDates: [CalendarDateException]
    let trips: [Trip]
}

struct Station: Codable, Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let latitude: Double
    let longitude: Double
    let zone: String
    let url: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct ServiceCalendar: Codable {
    let serviceId: String
    let weekdays: Weekdays
    let startDate: String
    let endDate: String
}

struct Weekdays: Codable {
    let monday: Bool
    let tuesday: Bool
    let wednesday: Bool
    let thursday: Bool
    let friday: Bool
    let saturday: Bool
    let sunday: Bool

    func contains(_ weekday: Int) -> Bool {
        switch weekday {
        case 1: sunday
        case 2: monday
        case 3: tuesday
        case 4: wednesday
        case 5: thursday
        case 6: friday
        case 7: saturday
        default: false
        }
    }
}

struct CalendarDateException: Codable {
    let serviceId: String
    let date: String
    let exceptionType: Int
}

struct Trip: Codable, Identifiable {
    let id: String
    let serviceId: String
    let headsign: String
    let directionId: Int?
    let bikesAllowed: Bool
    let wheelchairAccessible: Bool
    let stopTimes: [StopTime]
}

struct StopTime: Codable {
    let stopId: String
    let arrival: String
    let departure: String
    let sequence: Int
}

struct Departure: Identifiable {
    let id = UUID()
    let trip: Trip
    let origin: Station
    let destination: Station
    let originTime: StopTime
    let destinationTime: StopTime
    let serviceDate: Date
    let departureDate: Date
    let arrivalDate: Date
    let routeSequenceIndex: Int
    let scheduleAdjustment: ScheduleAdjustment?

    var deviatesFromStandardSchedule: Bool {
        scheduleAdjustment != nil
    }

    var travelMinutes: Int {
        max(0, Int(arrivalDate.timeIntervalSince(departureDate) / 60))
    }

    var directionLabel: String {
        trip.headsign == "Philadelphia" ? "Westbound" : "Eastbound"
    }

    var fullDirectionLabel: String {
        "\(directionLabel) to \(trip.headsign)"
    }

    func withScheduleAdjustment(_ adjustment: ScheduleAdjustment?, routeSequenceIndex: Int) -> Departure {
        Departure(
            trip: trip,
            origin: origin,
            destination: destination,
            originTime: originTime,
            destinationTime: destinationTime,
            serviceDate: serviceDate,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            routeSequenceIndex: routeSequenceIndex,
            scheduleAdjustment: adjustment
        )
    }
}

struct ScheduleAdjustment {
    let originalDepartureDate: Date?
}

struct PATCOSpecialSchedule: Codable, Equatable {
    struct ScheduledTrip: Codable, Equatable {
        let directionId: Int
        let stopTimes: [String]
    }

    let title: String
    let serviceDate: Date
    let sourceURL: URL
    let trips: [ScheduledTrip]
}

struct ActiveSpecialSchedule: Equatable {
    let title: String
    let serviceDate: Date
    let sourceURL: URL
    let tripCount: Int
}

enum ScheduleLoadError: LocalizedError {
    case missingResource

    var errorDescription: String? {
        "The bundled PATCO schedule could not be loaded."
    }
}

struct PATCOFeedMetadata: Codable {
    let downloadedAt: Date
    let feedStartDate: String
    let feedEndDate: String
    let feedVersion: String?
    let sourceURL: URL
}

enum PATCOFeedCache {
    private static let appGroup = "group.com.rhome.patconext"
    private static let scheduleDirectory = "Schedules"
    private static let feedFilename = "patco_schedule.json"
    private static let metadataFilename = "metadata.json"

    static func load() -> PATCOFeed? {
        guard let data = try? Data(contentsOf: feedURL) else { return nil }
        return try? JSONDecoder().decode(PATCOFeed.self, from: data)
    }

    static func loadMetadata() -> PATCOFeedMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PATCOFeedMetadata.self, from: data)
    }

    static func save(_ feed: PATCOFeed, metadata: PATCOFeedMetadata) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let feedData = try JSONEncoder().encode(feed)
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        let metadataData = try metadataEncoder.encode(metadata)

        try feedData.write(to: feedURL, options: .atomic)
        try metadataData.write(to: metadataURL, options: .atomic)
    }

    private static var directoryURL: URL {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return container.appendingPathComponent(scheduleDirectory, isDirectory: true)
    }

    private static var feedURL: URL {
        directoryURL.appendingPathComponent(feedFilename)
    }

    private static var metadataURL: URL {
        directoryURL.appendingPathComponent(metadataFilename)
    }
}

extension PATCOFeed {
    var startDate: String? {
        calendars.map(\.startDate).min()
    }

    var endDate: String? {
        calendars.map(\.endDate).max()
    }

    var serviceEndDate: Date? {
        guard let endDate else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: endDate)
    }

    func isExpired(on date: Date = Date()) -> Bool {
        guard let serviceEndDate,
              let expirationDate = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: 1,
                to: serviceEndDate
              ) else {
            return true
        }
        return date >= expirationDate
    }
}

final class PATCOScheduleStore: ObservableObject {
    @Published private(set) var feed: PATCOFeed?
    @Published private(set) var loadError: Error?
    @Published private(set) var activeSpecialSchedule: ActiveSpecialSchedule?

    private var baseFeed: PATCOFeed?
    private var specialFeedsByDateKey: [String: PATCOFeed] = [:]
    private var specialSchedulesByDateKey: [String: ActiveSpecialSchedule] = [:]
    private var stationById: [String: Station] = [:]
    private var calendar = Calendar(identifier: .gregorian)

    init() {
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        load()
    }

    func load() {
        do {
            let decoded: PATCOFeed
            if let cachedFeed = PATCOFeedCache.load() {
                decoded = cachedFeed
            } else {
                guard let url = Bundle.main.url(forResource: "patco_schedule", withExtension: "json") else {
                    throw ScheduleLoadError.missingResource
                }
                decoded = try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf: url))
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

    var scheduleFeedEndDate: Date? {
        baseFeed?.serviceEndDate
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
        let trips = schedule.trips.enumerated().map { index, scheduledTrip in
            let stationOrder = scheduledTrip.directionId == 0 ? baseFeed.stops : Array(baseFeed.stops.reversed())

            return Trip(
                id: "\(serviceId) Trip \(index + 1)",
                serviceId: serviceId,
                headsign: scheduledTrip.directionId == 0 ? "Philadelphia" : "Lindenwold",
                directionId: scheduledTrip.directionId,
                bikesAllowed: true,
                wheelchairAccessible: true,
                stopTimes: scheduledTrip.stopTimes.enumerated().map { stopIndex, time in
                    StopTime(
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
        specialSchedulesByDateKey[ymd] = ActiveSpecialSchedule(title: schedule.title, serviceDate: schedule.serviceDate, sourceURL: schedule.sourceURL, tripCount: trips.count)
    }

    func clearSpecialSchedule() {
        specialFeedsByDateKey = [:]
        specialSchedulesByDateKey = [:]
        feed = baseFeed
        activeSpecialSchedule = nil
    }

    func departures(from origin: Station, to destination: Station, after date: Date = Date(), limit: Int? = 10) -> [Departure] {
        guard let feed else { return [] }

        let standardDepartures = standardScheduleDepartures(from: origin, to: destination, after: date)
        var results: [Departure] = []
        for dayOffset in 0...1 {
            guard let serviceDate = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: date)) else {
                continue
            }

            let serviceFeed = feedForServiceDate(serviceDate) ?? feed
            let activeServices = activeServiceIds(on: serviceDate, feed: serviceFeed)
            let dayResults = serviceFeed.trips.compactMap {
                departure(
                    for: $0,
                    origin: origin,
                    destination: destination,
                    serviceDate: serviceDate,
                    activeServices: activeServices
                )
            }
                .filter { dayOffset > 0 || $0.departureDate >= date }
                .sorted { $0.departureDate < $1.departureDate }
            let standardDeparturesForServiceDate = standardDeparturesForSpecialSchedule(on: serviceDate, from: standardDepartures)?.filter {
                dayOffset > 0 || $0.departureDate >= date
            }
            let comparedDayResults = standardDeparturesForServiceDate.map {
                departuresWithScheduleAdjustments(dayResults, standardDepartures: $0)
            } ?? dayResults

            results.append(contentsOf: comparedDayResults)
            if let limit, results.count >= limit {
                break
            }
        }

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

    private func standardDeparturesForSpecialSchedule(on serviceDate: Date, from standardDepartures: [Departure]?) -> [Departure]? {
        let dateKey = Self.yyyymmddFormatter.string(from: serviceDate)
        guard specialFeedsByDateKey[dateKey] != nil else {
            return nil
        }

        return standardDepartures?.filter {
            calendar.isDate($0.serviceDate, inSameDayAs: serviceDate)
        }
    }

    private func standardScheduleDepartures(from origin: Station, to destination: Station, after date: Date) -> [Departure]? {
        guard activeSpecialSchedule != nil, let baseFeed else { return nil }

        var departures: [Departure] = []
        for dayOffset in 0...1 {
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
        activeServices: Set<String>
    ) -> Departure? {
        guard activeServices.contains(trip.serviceId),
              let originTime = trip.stopTimes.first(where: { $0.stopId == origin.id }),
              let destinationTime = trip.stopTimes.first(where: { $0.stopId == destination.id }),
              originTime.sequence < destinationTime.sequence,
              let departureDate = absoluteDate(serviceDate: serviceDate, timeString: originTime.departure),
              let arrivalDate = absoluteDate(serviceDate: serviceDate, timeString: destinationTime.arrival) else {
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
            scheduleAdjustment: nil
        )
    }

    private func departuresWithScheduleAdjustments(_ departures: [Departure], standardDepartures: [Departure]) -> [Departure] {
        departures.enumerated().map { index, departure in
            let exactStandardDeparture = standardDepartures.first {
                comparisonKey(for: $0) == comparisonKey(for: departure)
            }
            let nearestStandardDeparture = closestStandardDeparture(to: departure, in: standardDepartures)
            let adjustment = exactStandardDeparture == nil ? ScheduleAdjustment(originalDepartureDate: nearestStandardDeparture?.departureDate) : nil
            return departure.withScheduleAdjustment(adjustment, routeSequenceIndex: index)
        }
    }

    private func closestStandardDeparture(to departure: Departure, in standardDepartures: [Departure]) -> Departure? {
        standardDepartures.min { left, right in
            abs(left.departureDate.timeIntervalSince(departure.departureDate)) < abs(right.departureDate.timeIntervalSince(departure.departureDate))
        }
    }

    private func comparisonKey(for departure: Departure) -> String {
        comparisonKey(departureDate: departure.departureDate, arrivalDate: departure.arrivalDate)
    }

    private func comparisonKey(departureDate: Date, arrivalDate: Date) -> String {
        "\(Int(departureDate.timeIntervalSince1970 / 60))|\(Int(arrivalDate.timeIntervalSince1970 / 60))"
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

    private func absoluteDate(serviceDate: Date, timeString: String) -> Date? {
        let pieces = timeString.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }

        let seconds = pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        return calendar.date(byAdding: .second, value: seconds, to: serviceDate)
    }

    static let yyyymmddFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

enum SharedTravelTimeEstimateCache {
    enum Mode: String, Codable {
        case walking
        case driving
    }

    struct Estimate: Codable {
        let originId: Station.ID
        let sourceLatitude: Double
        let sourceLongitude: Double
        let minutes: Int
        let fetchedAt: Date

        func isValid(for origin: Station, currentLocation: CLLocation) -> Bool {
            originId == origin.id
                && Date().timeIntervalSince(fetchedAt) < 5 * 60
                && sourceLocation.distance(from: currentLocation) < 250
        }

        private var sourceLocation: CLLocation {
            CLLocation(latitude: sourceLatitude, longitude: sourceLongitude)
        }
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let walkingKey = "cachedWalkingTravelTimeEstimate"
    private static let drivingKey = "cachedDrivingTravelTimeEstimate"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func save(mode: Mode, origin: Station, currentLocation: CLLocation, minutes: Int, fetchedAt: Date = Date()) {
        let estimate = Estimate(
            originId: origin.id,
            sourceLatitude: currentLocation.coordinate.latitude,
            sourceLongitude: currentLocation.coordinate.longitude,
            minutes: minutes,
            fetchedAt: fetchedAt
        )

        if let data = try? JSONEncoder().encode(estimate) {
            defaults.set(data, forKey: key(for: mode))
        }
    }

    static func estimate(mode: Mode, origin: Station, currentLocation: CLLocation) -> Estimate? {
        guard let data = defaults.data(forKey: key(for: mode)),
              let estimate = try? JSONDecoder().decode(Estimate.self, from: data),
              estimate.isValid(for: origin, currentLocation: currentLocation) else {
            return nil
        }

        return estimate
    }

    static func clear(mode: Mode) {
        defaults.removeObject(forKey: key(for: mode))
    }

    private static func key(for mode: Mode) -> String {
        switch mode {
        case .walking:
            walkingKey
        case .driving:
            drivingKey
        }
    }
}

enum SharedReachabilityModeStore {
    enum Mode: String, Codable {
        case walking
        case driving
    }

    private struct Snapshot: Codable {
        let originId: Station.ID
        let mode: Mode
        let selectedAt: Date
        let isManual: Bool?
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let snapshotKey = "stickyReachabilityMode"
    private static let maxAge: TimeInterval = 3 * 60 * 60
    private static let atStationMeters = 150.0
    private static let closeEnoughToWalkMeters = 0.75 * 1_609.34
    private static let farEnoughToDriveMeters = 1.25 * 1_609.34
    private static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func resolve(
        originId: Station.ID,
        distanceToStation: CLLocationDistance,
        minutesUntilDeparture: Int,
        now: Date = Date()
    ) -> Mode? {
        guard distanceToStation > atStationMeters,
              distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        if let snapshot = snapshot(now: now), snapshot.originId == originId {
            if snapshot.isManual == true {
                return snapshot.mode
            }

            if snapshot.mode == .driving {
                return .driving
            }

            if distanceToStation < farEnoughToDriveMeters {
                return .walking
            }
        }

        let mode = inferredMode(
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        )
        save(mode: mode, originId: originId, now: now, isManual: false)
        return mode
    }

    static func save(
        mode: Mode,
        originId: Station.ID,
        now: Date = Date(),
        isManual: Bool = true
    ) {
        let snapshot = Snapshot(
            originId: originId,
            mode: mode,
            selectedAt: now,
            isManual: isManual
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    @discardableResult
    static func clearOnArrival(originId: Station.ID) -> Bool {
        guard let snapshot = snapshot(now: Date()), snapshot.originId == originId else {
            return false
        }

        defaults.removeObject(forKey: snapshotKey)
        return true
    }

    private static func snapshot(now: Date) -> Snapshot? {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            defaults.removeObject(forKey: snapshotKey)
            return nil
        }

        if snapshot.isManual != true,
           now.timeIntervalSince(snapshot.selectedAt) > maxAge {
            defaults.removeObject(forKey: snapshotKey)
            return nil
        }

        return snapshot
    }

    private static func inferredMode(
        distanceToStation: CLLocationDistance,
        minutesUntilDeparture: Int
    ) -> Mode {
        if distanceToStation <= closeEnoughToWalkMeters {
            return .walking
        }

        if distanceToStation >= farEnoughToDriveMeters {
            return .driving
        }

        let walkingMinutes = max(1, Int(ceil((distanceToStation / 1.25) / 60)))
        return minutesUntilDeparture - walkingMinutes >= 0 ? .walking : .driving
    }
}

enum SharedCurrentLocationCache {
    struct Snapshot: Codable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let timestamp: Date

        var location: CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: horizontalAccuracy,
                verticalAccuracy: -1,
                timestamp: timestamp
            )
        }
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let locationKey = "cachedCurrentLocation"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func save(_ location: CLLocation) {
        let snapshot = Snapshot(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )

        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: locationKey)
        }
    }

    static func location(maxAge: TimeInterval = 10 * 60) -> CLLocation? {
        guard let data = defaults.data(forKey: locationKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              Date().timeIntervalSince(snapshot.timestamp) <= maxAge else {
            return nil
        }

        return snapshot.location
    }
}
