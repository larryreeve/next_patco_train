import Combine
import CoreLocation
import Foundation
import Darwin

enum PATCOClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    static func isRepeatedTime(_ date: Date) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let first = calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: parts.second!,
                                  of: date, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: parts.second!,
                                 of: date, matchingPolicy: .strict, repeatedTimePolicy: .last)
        return first != nil && last != nil && first != last
    }

    static func needsTimeZone(_ date: Date, relativeTo other: Date? = nil) -> Bool {
        isRepeatedTime(date) || other.map {
            calendar.timeZone.secondsFromGMT(for: date) != calendar.timeZone.secondsFromGMT(for: $0)
        } == true
    }

    static func timeZoneSuffix(_ date: Date, relativeTo other: Date? = nil) -> String {
        needsTimeZone(date, relativeTo: other) ? " \(calendar.timeZone.abbreviation(for: date) ?? "ET")" : ""
    }

    static func timeText(_ date: Date, locale: Locale = .current, relativeTo other: Date? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date) + timeZoneSuffix(date, relativeTo: other)
    }

    static func accessibleTimeText(_ date: Date, now: Date = Date(), relativeTo other: Date? = nil) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            day = formatter.string(from: date)
        }
        return "\(day), \(timeText(date, relativeTo: other))"
    }
}

enum LocationDiagnosticFormatting {
    static func nearbyStation(_ location: CLLocation?, stations: [Station], now: Date = Date()) -> String {
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
              (0...30).contains(now.timeIntervalSince(location.timestamp)), !stations.isEmpty else { return "Unavailable" }
        guard let nearest = stations.filter({ CLLocationCoordinate2DIsValid($0.coordinate) }).min(by: {
            location.distance(from: $0.location) < location.distance(from: $1.location)
        }) else { return "Unavailable" }
        guard location.distance(from: nearest.location) <= LocationGuidancePolicy.stationRadiusMeters else { return "None" }
        return location.horizontalAccuracy > 50 ? "\(nearest.name) (estimated)" : nearest.name
    }

    static func eligibility(_ location: CLLocation, now: Date = Date()) -> String {
        "guidance eligible (180 sec/150 m): \(LocationGuidancePolicy.isUsable(location, maxAge: 180, now: now)); "
        + "station reading eligible (15 sec/50 m): \(CurrentStationEvidence.isPresenceReading(location, now: now)); "
        + "station boundary and ambiguity evaluated separately"
    }

    static func speedInMPH(_ speed: CLLocationSpeed, locale: Locale = .current) -> String {
        guard speed.isFinite, speed >= 0 else { return "Unavailable" }
        let mph = Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
            .converted(to: .milesPerHour).value
        return "\(mph.formatted(.number.precision(.fractionLength(1)).locale(locale))) mph"
    }
}

enum LocationGuidancePolicy {
    static let stationRadiusMeters = 150.0

    static func nearestUnambiguousStation(_ location: CLLocation, stations: [Station], now: Date = Date()) -> Station? {
        guard isUsable(location, maxAge: 30, now: now),
              CLLocationCoordinate2DIsValid(location.coordinate),
              let nearest = stations.min(by: { location.distance(from: $0.location) < location.distance(from: $1.location) }) else { return nil }
        let distance = location.distance(from: nearest.location)
        guard stations.filter({ $0.id != nearest.id }).allSatisfy({
            location.distance(from: $0.location) - distance >= max(75, 2 * location.horizontalAccuracy)
        }) else { return nil }
        return nearest
    }

    static func detectedStation(_ location: CLLocation, stations: [Station], now: Date = Date()) -> Station? {
        guard let station = nearestUnambiguousStation(location, stations: stations, now: now),
              isAtStation(location, station: station.location, now: now) else { return nil }
        return station
    }

    static func shouldSuppressArrival(location: CLLocation?, station: CLLocation?, now: Date = Date()) -> Bool {
        guard let location, let station,
              CLLocationCoordinate2DIsValid(location.coordinate),
              CLLocationCoordinate2DIsValid(station.coordinate),
              (0...60).contains(now.timeIntervalSince(location.timestamp)),
              location.horizontalAccuracy > 0, location.horizontalAccuracy <= 300 else { return false }
        return location.distance(from: station) <= 150 + location.horizontalAccuracy
    }

    static func isUsable(_ location: CLLocation, maxAge: TimeInterval = 120, now: Date = Date()) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && (0...maxAge).contains(now.timeIntervalSince(location.timestamp))
            && location.horizontalAccuracy > 0 && location.horizontalAccuracy <= 150
    }

    static func isAtStation(_ location: CLLocation, station: CLLocation, now: Date = Date()) -> Bool {
        isUsable(location, maxAge: 30, now: now)
            && location.distance(from: station) + location.horizontalAccuracy <= stationRadiusMeters
    }

    static func hasLeftStation(_ location: CLLocation, station: CLLocation, now: Date = Date()) -> Bool {
        isUsable(location, maxAge: 30, now: now)
            && location.distance(from: station) - location.horizontalAccuracy > stationRadiusMeters
    }
}

struct StationStopEvidence: Codable, Equatable {
    private var stationId: String?
    private var firstAt: Date?
    private var lastAt: Date?
    private var latitude: Double?
    private var longitude: Double?
    private var missingSpeedWindow: Bool?
    private var sampleCount: Int?

    static func isReliableStop(_ location: CLLocation, now: Date) -> Bool {
        LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now)
            && location.horizontalAccuracy <= 50
            && location.speed.isFinite && location.speed >= 0 && location.speed <= 0.5
    }

    static func isPresenceReading(_ location: CLLocation, now: Date) -> Bool {
        isReliableStop(location, now: now)
            || (LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now)
                && location.horizontalAccuracy <= 10 && location.speed == -1)
    }

    func diagnosticDescription(for location: CLLocation, now: Date = Date(), preciseArrival: Bool = false, positionPresence: Bool = false) -> String {
        guard LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now) else {
            return "Reading stale, invalid or inaccurate"
        }
        guard positionPresence ? CurrentStationEvidence.isPositionReading(location, now: now) : Self.isPresenceReading(location, now: now) else {
            if location.speed == -1 {
                return "Speed unavailable; presence requires accuracy within \(positionPresence ? 30 : 10) m"
            }
            if location.horizontalAccuracy > 50 {
                return "Stop confirmation requires accuracy within 50 m"
            }
            return "Not stopped; reported speed \(String(format: "%.1f", location.speed)) m/sec (maximum 0.5)"
        }
        let seconds = firstAt.flatMap { first in lastAt.map { max(0, Int($0.timeIntervalSince(first))) } } ?? 0
        return "Stopped evidence \(seconds) of \(preciseArrival ? 5 : 10) sec; \(sampleCount ?? 0) unique fixes; gaps over 15 sec restart confirmation"
    }

    mutating func accepts(stationId: String, station: CLLocation, location: CLLocation,
                          nearestOtherDistance: Double = .infinity, allowMissingSpeed: Bool = false,
                          now: Date = Date(), preciseArrival: Bool = false, positionPresence: Bool = false) -> Bool {
        // Duplicate callbacks and timer ticks cannot create dwell evidence.
        if let lastAt, location.timestamp < lastAt { return false }
        // Position-only presence tolerates missing speed, but never a reported moving fix.
        let missingSpeed = positionPresence || (allowMissingSpeed && location.speed == -1)
        guard (positionPresence ? CurrentStationEvidence.isPositionReading(location, now: now)
                : allowMissingSpeed ? Self.isPresenceReading(location, now: now) : Self.isReliableStop(location, now: now)),
              !preciseArrival || (Self.isReliableStop(location, now: now) && location.horizontalAccuracy <= 20),
              CLLocationCoordinate2DIsValid(station.coordinate),
              location.distance(from: station) + location.horizontalAccuracy <= LocationGuidancePolicy.stationRadiusMeters,
              nearestOtherDistance - location.distance(from: station) >= max(75, 2 * location.horizontalAccuracy) else {
            self = Self()
            return false
        }
        let anchor = latitude.flatMap { lat in longitude.map { CLLocation(latitude: lat, longitude: $0) } }
        if self.stationId != stationId || firstAt == nil || (missingSpeedWindow ?? false) != missingSpeed
            || lastAt.map({ location.timestamp.timeIntervalSince($0) > 15 }) == true
            || anchor.map({ location.distance(from: $0) > (missingSpeed || preciseArrival ? 10 : 20) }) == true {
            self.stationId = stationId
            firstAt = location.timestamp
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
            missingSpeedWindow = missingSpeed
            sampleCount = 0
        }
        if lastAt != location.timestamp { sampleCount = (sampleCount ?? 0) + 1 }
        lastAt = location.timestamp
        return firstAt.map {
            location.timestamp.timeIntervalSince($0) >= (preciseArrival ? 5 : 10)
                && (!preciseArrival || (sampleCount ?? 0) >= 2)
                && (!missingSpeed || (sampleCount ?? 0) >= 5)
        } ?? false
    }
}

// Displaying the current station is independent of confirming destination arrival.
// Coarse underground fixes can suggest a departure station, never confirm arrival.
struct UndergroundDepartureEvidence {
    private var route: [String] = []
    private var progress: Int?
    private var anchorAt: Date?
    private var lastAt: Date?
    private var candidate: String?
    private var candidateSince: Date?
    private var count = 0

    mutating func observe(route: [String], stationId: String?, reliable: Bool,
                          underground: Bool, distance: Double, otherDistance: Double,
                          location: CLLocation, journeyActive: Bool, now: Date = Date()) -> String? {
        if self.route != route { self = Self(); self.route = route }
        guard (0...15).contains(now.timeIntervalSince(location.timestamp)),
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= 3000 else {
            candidate = nil; count = 0
            return nil
        }
        if let lastAt, location.timestamp <= lastAt { return nil }
        if let lastAt, location.timestamp.timeIntervalSince(lastAt) > 45 { candidate = nil; count = 0 }
        lastAt = location.timestamp
        guard let stationId, let index = route.firstIndex(of: stationId) else {
            candidate = nil; count = 0
            return nil
        }
        if reliable {
            if index >= (progress ?? -1) { progress = index; anchorAt = now }
            candidate = nil; count = 0
            return nil
        }
        guard journeyActive, let progress, index >= progress, index < route.count - 1,
              let anchorAt, now.timeIntervalSince(anchorAt) <= 1800,
              underground, distance <= 150, otherDistance - distance >= 75 else {
            candidate = nil; count = 0
            return nil
        }
        if candidate != stationId {
            candidate = stationId; candidateSince = location.timestamp; count = 0
        }
        count += 1
        guard count >= 3, let candidateSince,
              location.timestamp.timeIntervalSince(candidateSince) >= 10 else { return nil }
        self.progress = index
        return stationId
    }
}

struct CurrentStationEvidence {
    private var lastAt: Date?

    static func isPositionReading(_ location: CLLocation, now: Date) -> Bool {
        LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now)
            && location.horizontalAccuracy <= 30
            && (location.speed == -1 || (location.speed.isFinite && location.speed >= 0 && location.speed <= 0.5))
    }

    static func isPresenceReading(_ location: CLLocation, now: Date) -> Bool {
        LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now)
            && location.horizontalAccuracy <= 50
    }

    mutating func accepts(stationId: String, station: CLLocation, location: CLLocation,
                          nearestOtherDistance: Double = .infinity, now: Date = Date()) -> Bool {
        if let lastAt, location.timestamp < lastAt { return false }
        lastAt = location.timestamp
        // Station presence means being inside its area, including while passing through.
        // Destination reversal remains the responsibility of DestinationArrivalGate.
        guard Self.isPresenceReading(location, now: now),
              CLLocationCoordinate2DIsValid(station.coordinate) else { return false }
        let distance = location.distance(from: station)
        return distance + location.horizontalAccuracy <= LocationGuidancePolicy.stationRadiusMeters
            && nearestOtherDistance - distance >= max(75, 2 * location.horizontalAccuracy)
    }

    func diagnosticDescription(for location: CLLocation, now: Date = Date()) -> String {
        guard Self.isPresenceReading(location, now: now) else {
            return "Station boundary requires a reading at most 15 sec old with accuracy within 50 m"
        }
        if let lastAt, location.timestamp < lastAt { return "Out-of-order location reading" }
        return "Station boundary requires distance plus accuracy within 150 m and an unambiguous station; no stop required"
    }
}

enum LocationInteractionPolicy {
    static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        // Preserve iOS's when-in-use value in the macOS command-line policy checks.
        return status == .authorizedAlways || status.rawValue == 4
        #else
        status == .authorizedAlways || status == .authorizedWhenInUse
        #endif
    }

    static func freshSelectionLocation(_ location: CLLocation?, requestedAt: Date, now: Date = Date()) -> CLLocation? {
        guard let location, location.timestamp >= requestedAt,
              LocationGuidancePolicy.isUsable(location, maxAge: 30, now: now),
              CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        return location
    }

    static func recentSelectionLocation(_ location: CLLocation?, maxAge: TimeInterval, now: Date = Date()) -> CLLocation? {
        guard let location, LocationGuidancePolicy.isUsable(location, maxAge: maxAge, now: now),
              location.horizontalAccuracy <= 75 else { return nil }
        return location
    }

    static func shouldRunUpdates(authorization: CLAuthorizationStatus, isForeground: Bool,
                                 trackingDeadline: Date?, now: Date = Date()) -> Bool {
        guard isAuthorized(authorization) else { return false }
        return isForeground || trackingDeadline.map {
            (0 < $0.timeIntervalSince(now)) && ($0.timeIntervalSince(now) <= 7200)
        } == true
    }
}

struct NearestStationSelectionRequest {
    enum Outcome: Equatable {
        case waiting, cancelled, denied, timedOut, routeChanged
        case staleLocation, inaccurateLocation, ambiguousStation, invalidLocation, stationsUnavailable
        case selected(SharedRouteCoordinator.Route)

        var failureMessage: String? {
            switch self {
            case .denied: return "Location is off. Your route is unchanged."
            case .timedOut: return "Location update did not arrive in time. Your route is unchanged."
            case .routeChanged: return "Route changed. Tap again to find the nearest station."
            case .staleLocation: return "Location reading is too old. Your route is unchanged."
            case .inaccurateLocation: return "Location accuracy is too low to select a station. Your route is unchanged."
            case .ambiguousStation: return "Nearest station is unclear from your location. Your route is unchanged."
            case .invalidLocation: return "Location reading is invalid. Your route is unchanged."
            case .stationsUnavailable: return "Station data is unavailable. Your route is unchanged."
            case .waiting, .cancelled, .selected: return nil
            }
        }
    }
    let expectedRevision: Int
    let requestedAt: Date
    private var completion: Outcome?
    private(set) var usedRecentLocationFallback = false

    init(expectedRevision: Int, requestedAt: Date) {
        self.expectedRevision = expectedRevision
        self.requestedAt = requestedAt
    }

    mutating func poll(location: CLLocation?, authorization: CLAuthorizationStatus,
                       isForeground: Bool, isViewingToday: Bool, cancelled: Bool = false,
                       stations: [Station], now: Date = Date(), directory: URL? = nil) -> Outcome {
        if let completion { return completion }
        let outcome: Outcome
        if cancelled || !isForeground || !isViewingToday {
            outcome = .cancelled
        } else if authorization == .denied || authorization == .restricted {
            outcome = .denied
        } else {
            let elapsed = now.timeIntervalSince(requestedAt)
            let fresh = elapsed < 8
                ? LocationInteractionPolicy.freshSelectionLocation(location, requestedAt: requestedAt, now: now) : nil
            let recent = elapsed >= 2 && elapsed <= 9
                ? LocationInteractionPolicy.recentSelectionLocation(location, maxAge: elapsed >= 8 ? 30 : 10, now: now) : nil
            let current = SharedRouteCoordinator.current(directory: directory)
            let endpoints = current?.endpointStations(in: stations) ?? []
            if current?.revision != expectedRevision {
                outcome = .routeChanged
            } else if LocationInteractionPolicy.isAuthorized(authorization), let candidate = fresh ?? recent,
               endpoints.count == 2,
               LocationGuidancePolicy.nearestUnambiguousStation(candidate, stations: endpoints, now: now) != nil {
                usedRecentLocationFallback = fresh == nil
                if let route = SharedRouteCoordinator.selectNearestStation(expectedRevision: expectedRevision,
                location: candidate, stations: stations, now: now, directory: directory),
               route.revision == expectedRevision + 1, route.event == .nearest {
                    outcome = .selected(route)
                } else {
                    outcome = .routeChanged
                }
            } else if elapsed >= 8 {
                if elapsed > 9 || !LocationInteractionPolicy.isAuthorized(authorization) {
                    outcome = .timedOut
                } else if let location {
                    if !CLLocationCoordinate2DIsValid(location.coordinate)
                        || location.timestamp > now || location.horizontalAccuracy <= 0 {
                        outcome = .invalidLocation
                    } else if now.timeIntervalSince(location.timestamp) > 30 {
                        outcome = .staleLocation
                    } else if !location.horizontalAccuracy.isFinite || location.horizontalAccuracy > 75 {
                        outcome = .inaccurateLocation
                    } else if endpoints.count != 2 {
                        outcome = .stationsUnavailable
                    } else {
                        outcome = .ambiguousStation
                    }
                } else {
                    outcome = .timedOut
                }
            } else {
                return .waiting
            }
        }
        completion = outcome
        return outcome
    }
}

enum WidgetDepartureDay {
    static func groupLabel(for date: Date, previousDeparture: Date?, relativeTo reference: Date,
                           timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let previousDeparture, calendar.isDate(date, inSameDayAs: previousDeparture) { return nil }
        return label(for: date, relativeTo: reference, timeZone: timeZone)
    }

    static func label(for date: Date, relativeTo reference: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: reference) { return nil }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

enum WidgetReachabilitySettings {
    static let enabledKey = "widgetReachabilityEnabled"
    static let suiteName = "group.com.rhome.patconext"
    static var isEnabled: Bool {
        isEnabled(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }
    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }
}

enum WidgetActionProgress {
    enum Kind: String, Codable { case reverse, mode, refresh }
    struct Ticket: Codable, Equatable {
        let id: UUID
        let kind: Kind
        let startedAt: Date
        let expiresAt: Date

        func isActive(at date: Date) -> Bool { date >= startedAt && date < expiresAt }

        func permitsWork(reserving seconds: TimeInterval = 0, at date: Date = Date()) -> Bool {
            isActive(at: date) && date.addingTimeInterval(max(0, seconds)) < expiresAt.addingTimeInterval(-6)
        }
    }

    private static func locked<T>(directory: URL?, body: (URL) -> T?) -> T? {
        guard let root = directory ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetReachabilitySettings.suiteName) else { return nil }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return nil }
        let fd = open(root.appendingPathComponent("widget-action.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body(root.appendingPathComponent("widget-action.json"))
    }

    private static func read(_ file: URL) -> Ticket? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Ticket.self, from: $0) }
    }

    static func current(now: Date = Date(), directory: URL? = nil) -> Ticket? {
        locked(directory: directory) { file in
            guard let ticket = read(file), ticket.isActive(at: now) else { return nil }
            return ticket
        }
    }

    static func begin(_ kind: Kind, now: Date? = nil, directory: URL? = nil) -> Ticket? {
        locked(directory: directory) { file in
            // Sample after acquiring the lock: another process may have just started work.
            let now = now ?? Date()
            guard read(file)?.isActive(at: now) != true else { return nil }
            let ticket = Ticket(id: UUID(), kind: kind, startedAt: now, expiresAt: now.addingTimeInterval(30))
            do {
                try JSONEncoder().encode(ticket).write(to: file, options: .atomic)
                return ticket
            } catch { return nil }
        }
    }

    static func finish(_ ticket: Ticket, directory: URL? = nil) {
        let _: Bool? = locked(directory: directory) { file in
            guard read(file)?.id == ticket.id else { return false }
            do { try FileManager.default.removeItem(at: file); return true }
            catch { return false }
        }
    }
}

enum WidgetDepartureSelection {
    static func timelinePayload<T: Identifiable>(_ departures: [T], isRecommended: (T) -> Bool) -> [T] {
        let compact = prioritized(departures, limit: 3, isRecommended: isRecommended)
        let ids = Set(departures.prefix(10).map(\.id) + compact.map(\.id))
        return departures.filter { ids.contains($0.id) }
    }

    static func select<T>(_ departures: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        return Array(departures.prefix(limit))
    }

    static func prioritized<T>(_ departures: [T], limit: Int,
                               isRecommended: (T) -> Bool) -> [T] {
        guard limit > 0 else { return [] }
        guard let index = departures.firstIndex(where: isRecommended) else {
            return select(departures, limit: limit)
        }
        // Keep a consecutive window so the train just before the recommendation is never skipped.
        let start = limit > 1 ? max(0, index - 1) : index
        return Array(departures[start...].prefix(limit))
    }
}

enum WidgetTimelinePolicy {
    static func shouldAttemptLocation(lastAttempt: Date?, now: Date, manual: Bool,
                                      lastSuccessfulLocation: Date? = nil) -> Bool {
        guard !manual, let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // Bound automatic retries even when WidgetKit invokes multiple timelines close together.
        let succeeded = lastSuccessfulLocation.map { $0 >= lastAttempt && $0 <= now } ?? false
        return elapsed < 0 || elapsed >= (succeeded ? 180 : 300)
    }

    static func unconfirmedTimesByDay(schedules: [PATCOSpecialSchedule], dates: [Date]) -> [Date: Bool] {
        let days = Set(dates.map { PATCOClock.calendar.startOfDay(for: $0) })
        return Dictionary(uniqueKeysWithValues: days.map { day in
            (day, schedules.contains { $0.hasUnconfirmedTimes(on: day) })
        })
    }

    static func hasUsableGuidance(location: CLLocation?, at date: Date) -> Bool {
        location.map { LocationGuidancePolicy.isUsable($0, maxAge: 180, now: date) } ?? false
    }

    static func lockScreenRefresh(now: Date, trackingDeadline: Date?, hasActiveTrip: Bool) -> Date {
        let tracking = trackingDeadline.map { $0 > now && $0.timeIntervalSince(now) <= 7200 } ?? false
        return now.addingTimeInterval(tracking || hasActiveTrip ? 600 : 1800)
    }
    static func nextRefresh(now: Date, hasService: Bool, hasGuidance: Bool, locationTimestamp: Date?,
                            estimateTimestamp: Date? = nil,
                            reachabilityEnabled: Bool = true) -> (date: Date, reason: String) {
        guard hasService else { return (now.addingTimeInterval(1800), "No upcoming service") }
        guard reachabilityEnabled else { return (now.addingTimeInterval(900), "Schedule-only refresh") }
        guard hasGuidance, let locationTimestamp,
              (0...180).contains(now.timeIntervalSince(locationTimestamp)) else {
            return (now.addingTimeInterval(300), "Reachability unavailable; bounded retry")
        }
        // Future entries still expire stale guidance if WidgetKit delays this request.
        let expiry = min(locationTimestamp.addingTimeInterval(181),
                         estimateTimestamp?.addingTimeInterval(300) ?? .distantFuture)
        return (max(now.addingTimeInterval(60), expiry), "Reachability freshness refresh")
    }
    static func entryDates(now: Date, departures: [Date], guidanceExpiration: Date? = nil) -> [Date] {
        let end = now.addingTimeInterval(24 * 60 * 60)
        let changes = departures.map { $0.addingTimeInterval(1) }.filter { $0 > now && $0 <= end }
        let earlyUpdates = (0...15).map { now.addingTimeInterval(Double($0 * 60)) }
        let fallbackUpdates = (1...24).map { now.addingTimeInterval(Double($0 * 3600)) }
        let expiry = guidanceExpiration.map { $0 > now && $0 <= end ? [$0] : [] } ?? []
        let calendar = PATCOClock.calendar
        let startOfDay = calendar.startOfDay(for: now)
        let midnights = (1...2).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfDay) }
            .filter { $0 > now && $0 <= end }
        return Array(Set(changes + earlyUpdates + fallbackUpdates + expiry + midnights)).sorted()
    }
}

enum JourneyTrackingPolicy {
    static func shouldBegin(atOrigin: Bool, arrivalSuppressed: Bool, departedArrivalStation: Bool, explicitTrip: Bool) -> Bool {
        explicitTrip || (!arrivalSuppressed && (atOrigin || departedArrivalStation))
    }
}

enum SharedJourneyTracking {
    private static let key = "journeyTrackingDeadline"
    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard }
    static var deadline: Date? { defaults.object(forKey: key) as? Date }
    static func begin(until date: Date) { defaults.set(date, forKey: key) }
    static func end() { defaults.removeObject(forKey: key) }
}

struct JourneyProgressSession: Codable, Equatable {
    enum Termination: String, Codable { case arrived, cancelled, expired }
    struct Stop: Codable, Equatable {
        let name: String
        let arrival: Date
    }
    let key: String
    let deepLink: String
    let originName: String
    let destinationName: String
    let departure: Date
    let arrival: Date
    let stops: [Stop]
    var completed = false
    var termination: Termination?

    func isActive(at now: Date = Date()) -> Bool {
        !completed && termination == nil && !ScheduledTripExpiration.hasExpired(arrivalDate: arrival, now: now)
    }
}

enum JourneyRouteEvent: String, Codable {
    case backgroundArrival = "Background arrival"
    case estimatedArrival = "Estimated arrival"
    case appArrival = "App arrival"
    case confirmedArrival = "User confirmed arrival"
    case reversal = "Manual reversal"
    case selection = "Manual selection"
    case nearest = "Find nearest station"
    case recovery = "Return direction recovered; station arrival unconfirmed"
    case stationSelection = "Station departures selection"
    case stationRestored = "Station route restored"
    case bootstrap = "App route"
    case unknown

    var completesJourney: Bool {
        switch self {
        case .backgroundArrival, .estimatedArrival, .appArrival, .confirmedArrival: true
        default: false
        }
    }

    var endsTracking: Bool { completesJourney || self == .reversal || self == .recovery }
    var isTemporary: Bool { self == .stationSelection || self == .stationRestored }
}

enum ScheduledTripExpiration {
    static func deadline(arrivalDate: Date) -> Date {
        arrivalDate.addingTimeInterval(10 * 60)
    }

    static func hasExpired(arrivalDate: Date, now: Date = Date()) -> Bool {
        now >= deadline(arrivalDate: arrivalDate)
    }
}

enum TripSpeedPresentation {
    static func isDuringTrip(departure: Date, arrival: Date, now: Date) -> Bool {
        now >= departure && now < arrival
    }

    static func milesPerHour(_ location: CLLocation?, now: Date = Date()) -> Int? {
        guard let location,
              (0...10).contains(now.timeIntervalSince(location.timestamp)),
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy > 0, location.horizontalAccuracy <= 50,
              location.speed.isFinite, location.speed >= 0,
              location.speedAccuracy.isFinite,
              location.speedAccuracy >= 0, location.speedAccuracy <= 5,
              location.speed < 100 else { return nil }
        return Int((location.speed * 2.2369362921).rounded())
    }
}

struct PATCOTrackGeometry: Decodable {
    let shapes: [[[Double]]]

    static let bundled: PATCOTrackGeometry? = {
        guard let url = Bundle.main.url(forResource: "patco_tracks", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()

    func route(from origin: CLLocation, to destination: CLLocation) -> [CLLocationCoordinate2D] {
        var best: [CLLocationCoordinate2D] = []
        var bestDistance = Double.infinity
        for shape in shapes {
            let points = shape.compactMap { point -> CLLocation? in
                guard point.count == 2 else { return nil }
                let value = CLLocation(latitude: point[0], longitude: point[1])
                return CLLocationCoordinate2DIsValid(value.coordinate) ? value : nil
            }
            guard let start = points.indices.min(by: { points[$0].distance(from: origin) < points[$1].distance(from: origin) }),
                  let end = points.indices.min(by: { points[$0].distance(from: destination) < points[$1].distance(from: destination) }), start != end else { continue }
            let distance = points[start].distance(from: origin) + points[end].distance(from: destination)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            let segment = Array(points[min(start, end)...max(start, end)])
            best = (start < end ? segment : Array(segment.reversed())).map(\.coordinate)
        }
        return bestDistance <= 600 ? best : []
    }

    static func projection(of location: CLLocation, onto route: [CLLocationCoordinate2D]) -> (along: Double, offset: Double)? {
        let scale = 6_371_000.0 * Double.pi / 180
        let longitudeScale = scale * cos(location.coordinate.latitude * Double.pi / 180)
        var traversed = 0.0
        var best: (along: Double, offset: Double)?
        for (a, b) in zip(route, route.dropFirst()) {
            let ax = (a.longitude - location.coordinate.longitude) * longitudeScale
            let ay = (a.latitude - location.coordinate.latitude) * scale
            let dx = (b.longitude - a.longitude) * longitudeScale
            let dy = (b.latitude - a.latitude) * scale
            let lengthSquared = dx * dx + dy * dy
            let length = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let t = lengthSquared > 0 ? min(1, max(0, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let offset = hypot(ax + t * dx, ay + t * dy)
            if best.map({ offset < $0.offset }) ?? true { best = (traversed + t * length, offset) }
            traversed += length
        }
        return best
    }

    func isNearTrack(_ location: CLLocation) -> Bool {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy > 0, location.horizontalAccuracy <= 50 else { return false }
        // Local projection is sufficient for this short rail line. Clamp to actual segments,
        // not extended station-to-station lines; include uncertainty in the 100 m corridor.
        let latitudeScale = 6_371_000.0 * Double.pi / 180
        let longitudeScale = latitudeScale * cos(location.coordinate.latitude * Double.pi / 180)
        for shape in shapes {
            for (a, b) in zip(shape, shape.dropFirst()) {
                guard a.count == 2, b.count == 2,
                      CLLocationCoordinate2DIsValid(.init(latitude: a[0], longitude: a[1])),
                      CLLocationCoordinate2DIsValid(.init(latitude: b[0], longitude: b[1])) else { continue }
                let ax = (a[1] - location.coordinate.longitude) * longitudeScale
                let ay = (a[0] - location.coordinate.latitude) * latitudeScale
                let dx = (b[1] - a[1]) * longitudeScale
                let dy = (b[0] - a[0]) * latitudeScale
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared > 0 ? min(1, max(0, -(ax * dx + ay * dy) / lengthSquared)) : 0
                if hypot(ax + t * dx, ay + t * dy) + location.horizontalAccuracy <= 100 { return true }
            }
        }
        return false
    }
}

enum UrbanStationArrivalPolicy {
    static let intermediateConfirmationSeconds: TimeInterval = 5
    static let destinationConfirmationSeconds: TimeInterval = 10
    static let destinationMaximumReadingGap: TimeInterval = 90
    static let intermediateMinimumReadings = 2

    static func radius(accuracy: Double) -> Double {
        guard accuracy.isFinite, accuracy > 0 else { return 100 }
        return min(150, max(100, accuracy * 1.5))
    }

    static func isNearScheduledArrival(_ arrival: Date, now: Date) -> Bool {
        (-180...600).contains(now.timeIntervalSince(arrival))
    }
}

struct TripLocationProgress: Codable, Equatable {
    var detectedStationIds: Set<String> = []
    private(set) var inferredStationIds: Set<String>?
    var completedStationIds: Set<String> { detectedStationIds.union(inferredStationIds ?? []) }
    var lastStationIndex = -1
    var latitude: Double?
    var longitude: Double?
    var positionAt: Date?
    private(set) var arrivalAnchorStationId: Station.ID?
    private(set) var arrivalAnchorAt: Date?
    private var lastReadingAt: Date?
    private var urbanCandidateId: Station.ID?
    private var urbanFirstAt: Date?
    private var urbanLastAt: Date?
    private var urbanReadingCount: Int?

    struct MapPosition {
        let coordinate: CLLocationCoordinate2D
        let title: String
        let isFreshGPS: Bool
    }

    struct ArrivalEstimate {
        let date: Date
        let basis: String
        let observedAt: Date

        func arrival(at scheduledStop: Date, scheduledDestination: Date, now: Date) -> Date? {
            guard scheduledStop <= scheduledDestination else { return nil }
            let estimate = scheduledStop.addingTimeInterval(date.timeIntervalSince(scheduledDestination))
            return estimate >= now ? estimate : nil
        }

        func delayText(scheduled: Date) -> String {
            // Compare the displayed minutes, not a separately rounded seconds-level delay.
            let minutes = Int(floor(date.timeIntervalSince1970 / 60)
                - floor(scheduled.timeIntervalSince1970 / 60))
            if minutes == 0 { return "On time" }
            return minutes > 0 ? "\(minutes) min late" : "\(-minutes) min early"
        }
    }

    func arrivalEstimate(stations: [Station], scheduled: [Station.ID: Date],
                         geometry: PATCOTrackGeometry?, now: Date = Date()) -> ArrivalEstimate? {
        guard let first = stations.first, let last = stations.last, stations.count >= 2,
              let start = scheduled[first.id], let end = scheduled[last.id], now >= start,
              end > start, !completedStationIds.contains(last.id) else { return nil }
        if let position = mapPosition(stations: stations, geometry: geometry, now: now), position.isFreshGPS,
           let observedAt = positionAt, observedAt >= start, let geometry {
            let route = geometry.route(from: first.location, to: last.location)
            let location = CLLocation(latitude: position.coordinate.latitude, longitude: position.coordinate.longitude)
            if let projected = PATCOTrackGeometry.projection(of: location, onto: route), projected.offset <= 150 {
                for (left, right) in zip(stations, stations.dropFirst()) {
                    guard let a = PATCOTrackGeometry.projection(of: left.location, onto: route),
                          let b = PATCOTrackGeometry.projection(of: right.location, onto: route),
                          b.along > a.along, projected.along >= a.along, projected.along <= b.along,
                          let from = scheduled[left.id], let to = scheduled[right.id], to > from else { continue }
                    let fraction = (projected.along - a.along) / (b.along - a.along)
                    let scheduledPosition = from.addingTimeInterval(to.timeIntervalSince(from) * fraction)
                    let estimate = end.addingTimeInterval(observedAt.timeIntervalSince(scheduledPosition))
                    if estimate >= now {
                        return ArrivalEstimate(date: estimate, basis: "Based on current location", observedAt: observedAt)
                    }
                }
            }
        }
        // Only directly observed stations have an anchor; backfilled passed stops do not.
        guard let id = arrivalAnchorStationId, let observedAt = arrivalAnchorAt, observedAt >= start,
              (0...120).contains(now.timeIntervalSince(observedAt)),
              let station = stations.first(where: { $0.id == id }), let planned = scheduled[id] else { return nil }
        let estimate = end.addingTimeInterval(observedAt.timeIntervalSince(planned))
        guard estimate >= now else { return nil }
        return ArrivalEstimate(date: estimate,
            basis: "Based on \(station.name)\(detectedStationIds.contains(id) ? "" : " (estimated)")", observedAt: observedAt)
    }

    func mapPosition(stations: [Station], geometry: PATCOTrackGeometry?, now: Date = Date()) -> MapPosition? {
        let gps: CLLocation? = latitude.flatMap { latitude in
            longitude.map { CLLocation(latitude: latitude, longitude: $0) }
        }
        let completed = stations.last { completedStationIds.contains($0.id) }
        if let completed {
            let track = stations.first.flatMap { first in
                stations.last.flatMap { last in geometry?.route(from: first.location, to: last.location) }
            } ?? []
            let route = track.count > 1 ? track : stations.map(\.coordinate)
            let gpsAlong = gps.flatMap { PATCOTrackGeometry.projection(of: $0, onto: route)?.along }
            let stationAlong = PATCOTrackGeometry.projection(of: completed.location, onto: route)?.along
            let gpsAtOrBeyondStation = gpsAlong.flatMap { position in stationAlong.map { position >= $0 } } ?? false
            if positionAt == nil || !gpsAtOrBeyondStation {
                return MapPosition(coordinate: completed.coordinate,
                    title: detectedStationIds.contains(completed.id) ? "Last confirmed station" : "Estimated station position",
                    isFreshGPS: false)
            }
        }
        guard let gps, let positionAt else { return nil }
        let fresh = (0...15).contains(now.timeIntervalSince(positionAt))
        return MapPosition(coordinate: gps.coordinate,
                           title: fresh ? "Estimated train position" : "Last known position", isFreshGPS: fresh)
    }

    mutating func observe(_ location: CLLocation, stations: [Station], geometry: PATCOTrackGeometry?,
                          departure: Date, arrival: Date, now: Date = Date(),
                          stationArrivals: [Station.ID: Date] = [:]) {
        guard now >= departure, now < ScheduledTripExpiration.deadline(arrivalDate: arrival),
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.timestamp >= departure,
              lastReadingAt.map({ location.timestamp > $0 }) ?? true else { return }
        if !CurrentStationEvidence.isPresenceReading(location, now: now) {
            // Poor fixes can identify an estimated stop, but never move the train marker.
            guard (0...15).contains(now.timeIntervalSince(location.timestamp)),
                  location.horizontalAccuracy.isFinite, (50...2000).contains(location.horizontalAccuracy) else { return }
            lastReadingAt = location.timestamp
            let ranked = stations.enumerated().sorted {
                location.distance(from: $0.element.location) < location.distance(from: $1.element.location)
            }
            if let nearest = ranked.first, nearest.offset > lastStationIndex, lastStationIndex >= 0,
               nearest.element.supportsUndergroundReturnRecovery,
               let expected = stationArrivals[nearest.element.id],
               UrbanStationArrivalPolicy.isNearScheduledArrival(expected, now: now),
               location.speed.isFinite, location.speed < 0 || location.speed <= 2,
               location.distance(from: nearest.element.location) <= UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy),
               ranked.dropFirst().first.map({ location.distance(from: $0.element.location) - location.distance(from: nearest.element.location) >= 150 }) ?? true {
                if urbanCandidateId != nearest.element.id || urbanReadingCount == nil || urbanLastAt.map({ location.timestamp.timeIntervalSince($0) > 45 }) ?? true {
                    urbanCandidateId = nearest.element.id
                    urbanFirstAt = location.timestamp
                    urbanReadingCount = 0
                }
                urbanLastAt = location.timestamp
                urbanReadingCount = (urbanReadingCount ?? 0) + 1
                let isDestination = nearest.offset == stations.count - 1
                let duration = isDestination ? UrbanStationArrivalPolicy.destinationConfirmationSeconds
                    : UrbanStationArrivalPolicy.intermediateConfirmationSeconds
                let minimumReadings = isDestination ? 2 : UrbanStationArrivalPolicy.intermediateMinimumReadings
                if let first = urbanFirstAt, location.timestamp.timeIntervalSince(first) >= duration,
                   (urbanReadingCount ?? 0) >= minimumReadings {
                    inferredStationIds = (inferredStationIds ?? []).union([nearest.element.id])
                    lastStationIndex = nearest.offset
                    arrivalAnchorStationId = nearest.element.id
                    arrivalAnchorAt = location.timestamp
                }
            } else {
                urbanCandidateId = nil
                urbanFirstAt = nil
                urbanLastAt = nil
            }
            return
        }
        urbanCandidateId = nil
        urbanFirstAt = nil
        urbanLastAt = nil
        lastReadingAt = location.timestamp
        guard let nearest = stations.indices.min(by: {
            location.distance(from: stations[$0].location) < location.distance(from: stations[$1].location)
        }), nearest >= lastStationIndex else { return }
        let other = stations.indices.filter { $0 != nearest }
            .map { location.distance(from: stations[$0].location) }.min() ?? .infinity
        var evidence = CurrentStationEvidence()
        if evidence.accepts(stationId: stations[nearest].id, station: stations[nearest].location,
                            location: location, nearestOtherDistance: other, now: now) {
            detectedStationIds.insert(stations[nearest].id)
            lastStationIndex = nearest
            arrivalAnchorStationId = stations[nearest].id
            arrivalAnchorAt = location.timestamp
        }
        guard let geometry, let first = stations.first, let last = stations.last else { return }
        let route = geometry.route(from: first.location, to: last.location)
        let corridor = PATCOTrackGeometry(shapes: [route.map { [$0.latitude, $0.longitude] }])
        guard corridor.isNearTrack(location) else { return }
        if let position = PATCOTrackGeometry.projection(of: location, onto: route) {
            // Route order follows this trip's direction. Require the entire uncertainty
            // margin to be beyond the stop, and never infer destination arrival.
            for (index, station) in stations.dropLast().enumerated() {
                guard let stop = PATCOTrackGeometry.projection(of: station.location, onto: route),
                      stop.offset <= 150,
                      position.along - location.horizontalAccuracy > stop.along + 150 else { continue }
                if !detectedStationIds.contains(station.id) {
                    inferredStationIds = (inferredStationIds ?? []).union([station.id])
                }
                lastStationIndex = max(lastStationIndex, index)
            }
        }
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        positionAt = location.timestamp
    }
}

enum ScheduledDeparturePresentation {
    static func staleDate(departureDate: Date, arrivalDate: Date, now: Date = Date()) -> Date {
        now < departureDate ? departureDate : ScheduledTripExpiration.deadline(arrivalDate: arrivalDate)
    }

    static func hasDeparted(departureDate: Date, isStale: Bool, now: Date = Date()) -> Bool {
        isStale || now >= departureDate
    }
}

enum SharedWidgetRouteMemory {
    static func returnDestination(arrivingAt: String, currentOrigin: String, savedOrigin: String?, savedDestination: String?) -> String {
        if arrivingAt == savedDestination, let savedOrigin { return savedOrigin }
        if arrivingAt == savedOrigin, let savedDestination { return savedDestination }
        return currentOrigin
    }

}

struct UndergroundExitEvidence: Codable, Equatable {
    private var firstAt: Date?
    private var lastAt: Date?
    private var lastLatitude: Double?
    private var lastLongitude: Double?
    private var lastAccuracy: Double?
    private var samples = 0
    private(set) var decision = "Waiting for reliable evidence outside the rail corridor"

    mutating func accepts(location: CLLocation, destination: Station, stations: [Station], now: Date) -> Bool {
        guard lastAt.map({ location.timestamp > $0 }) ?? true else { return false }
        let distance = location.distance(from: destination.location)
        let otherDistance = stations.filter { $0.id != destination.id }
            .map { location.distance(from: $0.location) }.min() ?? 0
        let rejection: String?
        if !LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now) || location.horizontalAccuracy > 20 {
            rejection = "Exit recovery requires a reading at most 15 sec old with accuracy within 20 m"
        } else if !location.speed.isFinite || !(0...1.8).contains(location.speed) {
            rejection = "Exit recovery requires reported stopped/walking speed from 0 to 1.8 m/sec"
        } else if distance + location.horizontalAccuracy > 500 {
            rejection = "Outside exit-recovery area: distance plus accuracy \(Int(distance + location.horizontalAccuracy)) m exceeds 500 m"
        } else if distance - location.horizontalAccuracy <= LocationGuidancePolicy.stationRadiusMeters {
            rejection = "Exit recovery requires evidence beyond the 150 m station boundary"
        } else if otherDistance - distance < 100 + 2 * location.horizontalAccuracy {
            rejection = "Exit recovery cannot distinguish the selected destination from neighboring stations"
        } else if !Self.isOutsideRailCorridor(location, destination: destination, stations: stations) {
            rejection = "Waiting for reliable evidence outside the rail corridor"
        } else {
            rejection = nil
        }
        if let rejection {
            self = Self()
            decision = rejection
            return false
        }
        if let lastAt {
            let elapsed = location.timestamp.timeIntervalSince(lastAt)
            let previous = lastLatitude.flatMap { latitude in
                lastLongitude.map { CLLocation(latitude: latitude, longitude: $0) }
            }
            if elapsed > 20 || previous.map({
                location.distance(from: $0) > 2 * elapsed + (lastAccuracy ?? 0) + location.horizontalAccuracy
            }) != false {
                self = Self()
            }
        }
        if firstAt == nil { firstAt = location.timestamp }
        lastAt = location.timestamp
        lastLatitude = location.coordinate.latitude
        lastLongitude = location.coordinate.longitude
        lastAccuracy = location.horizontalAccuracy
        samples += 1
        let duration = location.timestamp.timeIntervalSince(firstAt!)
        let recovered = duration >= 30 && samples >= 4
        decision = recovered ? "Sustained stopped/walking evidence outside the rail corridor; arrival unconfirmed"
            : "Outside rail corridor: \(Int(duration)) of 30 sec; \(samples) of 4 distinct stopped/walking readings"
        return recovered
    }

    private static func isOutsideRailCorridor(_ location: CLLocation, destination: Station, stations: [Station]) -> Bool {
        guard let code = Int(destination.code), (8...14).contains(code) else { return false }
        let neighborCodes = code == 14 ? [13] : [code - 1, code + 1]
        let neighbors = neighborCodes.compactMap { code in stations.first { $0.code == String(code) } }
        guard neighbors.count == neighborCodes.count else { return false }
        // Deliberately wide, extended station-to-station centerlines exclude platforms,
        // approaches and slow trains. These are exclusion zones, not precise track maps.
        let radians = Double.pi / 180
        let latitudeScale = 6_371_000 * radians
        let longitudeScale = latitudeScale * cos(destination.latitude * radians)
        let x = (location.coordinate.longitude - destination.longitude) * longitudeScale
        let y = (location.coordinate.latitude - destination.latitude) * latitudeScale
        return neighbors.allSatisfy { neighbor in
            guard CLLocationCoordinate2DIsValid(neighbor.coordinate) else { return false }
            let dx = (neighbor.longitude - destination.longitude) * longitudeScale
            let dy = (neighbor.latitude - destination.latitude) * latitudeScale
            let length = hypot(dx, dy)
            guard length > 0 else { return false }
            return abs(x * dy - y * dx) / length - location.horizontalAccuracy > 200
        }
    }
}

struct ReturnDirectionEvidence: Codable, Equatable {
    private var originSideAt: Date?
    private var originSideDistance: Double?
    private var undergroundExit: UndergroundExitEvidence?
    private var destinationSeenAt: Date?
    private var candidateAt: Date?
    private var candidateDistance: Double?
    private var candidateAccuracy: Double?
    private var lastAt: Date?

    var undergroundDiagnostic: String? { undergroundExit?.decision }

    mutating func resetUndergroundCandidate() { undergroundExit = nil }

    mutating func accepts(location: CLLocation, origin: CLLocation, destination: CLLocation,
                          selectedAt: Date, now: Date, undergroundDestination: Station? = nil,
                          stations: [Station] = []) -> Bool {
        // Reused cached fixes are presentation data, not new journey observations.
        guard lastAt.map({ location.timestamp > $0 }) ?? true else { return false }
        guard location.timestamp > selectedAt,
              LocationGuidancePolicy.isUsable(location, maxAge: 30, now: now),
              location.horizontalAccuracy <= 75 else {
            candidateAt = nil
            candidateDistance = nil
            candidateAccuracy = nil
            undergroundExit = nil
            return false
        }
        let previousAt = lastAt
        lastAt = location.timestamp
        let fromOrigin = location.distance(from: origin)
        let fromDestination = location.distance(from: destination)
        let uncertainty = location.horizontalAccuracy
        // Require observed travel from the origin side, not merely opening the app in the city.
        if fromOrigin + uncertainty + 500 < fromDestination,
           fromOrigin + fromDestination <= origin.distance(from: destination) + 1000 {
            originSideAt = location.timestamp
            originSideDistance = fromDestination
            undergroundExit = nil
            destinationSeenAt = nil
            candidateAt = nil
            candidateDistance = nil
            candidateAccuracy = nil
            return false
        }
        guard let originSideAt, location.timestamp.timeIntervalSince(originSideAt) <= 12 * 60 * 60,
              fromDestination + uncertainty <= 1000,
              fromDestination + uncertainty + 500 < fromOrigin else {
            candidateAt = nil
            candidateDistance = nil
            candidateAccuracy = nil
            undergroundExit = nil
            return false
        }
        if let undergroundDestination {
            // A tunnel GPS gap need not include an observed station visit. Require a recent
            // origin-side journey and sustained, unambiguous evidence away from the tracks instead.
            guard location.timestamp.timeIntervalSince(originSideAt) <= 90 * 60,
                  let originSideDistance, fromDestination + uncertainty + 500 < originSideDistance else {
                undergroundExit = nil
                return false
            }
            var exit = undergroundExit ?? UndergroundExitEvidence()
            let recovered = exit.accepts(location: location, destination: undergroundDestination, stations: stations, now: now)
            undergroundExit = exit
            return recovered
        }
        // Proximity on the final approach is not evidence of a completed outbound trip.
        if fromDestination + uncertainty <= LocationGuidancePolicy.stationRadiusMeters {
            destinationSeenAt = location.timestamp
            candidateAt = nil
            candidateDistance = nil
            candidateAccuracy = nil
            return false
        }
        guard let destinationSeenAt, location.timestamp > destinationSeenAt,
              location.timestamp.timeIntervalSince(destinationSeenAt) <= 12 * 60 * 60,
              fromDestination - uncertainty > LocationGuidancePolicy.stationRadiusMeters else {
            candidateAt = nil
            candidateDistance = nil
            candidateAccuracy = nil
            return false
        }
        if candidateAt == nil || candidateDistance == nil || candidateAccuracy == nil
            || previousAt.map({ location.timestamp.timeIntervalSince($0) > 60 }) == true
            || candidateDistance.map({ fromDestination + uncertainty < $0 - (candidateAccuracy ?? 0) }) == true {
            candidateAt = location.timestamp
            candidateDistance = fromDestination
            candidateAccuracy = uncertainty
        }
        guard let candidateAt, let candidateDistance, let candidateAccuracy else { return false }
        return location.timestamp.timeIntervalSince(candidateAt) >= 10
            && fromDestination - uncertainty >= candidateDistance + candidateAccuracy + 25
    }
}

enum SharedRouteCoordinator {
    struct TemporaryRoute: Codable, Equatable {
        let originId: String
        let destinationId: String
        let manual: Bool
    }
    struct Route: Codable, Equatable {
        let originId: String
        let destinationId: String
        let savedOriginId: String
        let savedDestinationId: String
        let revision: Int
        let updatedAt: Date
        var lastLocationAt: Date?
        let reason: String
        let manual: Bool
        var blockedArrivalDestinationId: String?
        var temporaryRoute: TemporaryRoute? = nil
        var arrivalGate: DestinationArrivalGate? = nil
        var journeySelectedAt: Date? = nil
        var returnDirectionEvidence: ReturnDirectionEvidence? = nil
        var journey: JourneyProgressSession? = nil
        var journeyProgress: TripLocationProgress? = nil

        var event: JourneyRouteEvent { JourneyRouteEvent(rawValue: reason) ?? .unknown }

        var completesJourney: Bool {
            event.completesJourney
        }

        var endsJourneyTracking: Bool {
            event.endsTracking
        }

        func endpointStations(in stations: [Station]) -> [Station] {
            stations.filter { $0.id == savedOriginId || $0.id == savedDestinationId }
        }
    }
    private static let lock = NSLock()

    static func current(directory: URL? = nil) -> Route? {
        transaction(directory: directory) { _ in }
    }

    @discardableResult
    static func beginJourney(_ session: JourneyProgressSession, expectedRevision: Int,
                             now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  let url = URL(string: session.deepLink), let link = DepartureDeepLink(url: url),
                  (link.originId == old.originId || link.originId == old.temporaryRoute?.originId),
                  link.destinationId == old.destinationId, session.isActive(at: now),
                  old.journey?.key != session.key else { return }
            // A new Live Activity for the same trip must not erase progress or revive a completed trip.
            guard old.journey?.deepLink != session.deepLink || old.journey?.isActive(at: now) == true else { return }
            route?.journey = session
            if old.journey?.deepLink != session.deepLink { route?.journeyProgress = TripLocationProgress() }
        }
    }

    @discardableResult
    static func saveJourneyProgress(_ progress: TripLocationProgress, key: String,
                                    now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard route?.journey?.key == key, route?.journey?.isActive(at: now) == true else { return }
            route?.journeyProgress = progress
        }
    }

    @discardableResult
    static func expireJourney(now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let session = route?.journey, !session.completed, session.termination == nil,
                  ScheduledTripExpiration.hasExpired(arrivalDate: session.arrival, now: now) else { return }
            route?.journey?.termination = .expired
        }
    }

    @discardableResult
    static func destinationRegionEntered(stationId: String, expectedRevision: Int, stations: [Station],
                                         now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision, old.destinationId == stationId,
                  old.blockedArrivalDestinationId == nil, now > old.updatedAt,
                  stations.contains(where: { $0.id == stationId }) else { return }
            let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: stationId,
                currentOrigin: old.originId, savedOrigin: old.savedOriginId, savedDestination: old.savedDestinationId)
            guard returnId != stationId, stations.contains(where: { $0.id == returnId }) else { return }
            route = Route(originId: stationId, destinationId: returnId,
                savedOriginId: stationId, savedDestinationId: returnId,
                revision: old.revision + 1, updatedAt: now, lastLocationAt: nil,
                reason: JourneyRouteEvent.backgroundArrival.rawValue, manual: false)
        }
    }

    static func destinationRegionExited(stationId: String, expectedRevision: Int, directory: URL? = nil) {
        _ = transaction(directory: directory) { route in
            guard route?.revision == expectedRevision, route?.destinationId == stationId else { return }
            route?.blockedArrivalDestinationId = nil
            route?.arrivalGate = nil
        }
    }

    @discardableResult
    static func reverse(expectedRevision: Int, selectionLocation: CLLocation? = nil,
                        stations: [Station] = [], now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision else { return }
            route = Route(originId: old.destinationId, destinationId: old.originId,
                          savedOriginId: old.destinationId, savedDestinationId: old.originId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.reversal.rawValue, manual: true,
                          blockedArrivalDestinationId: LocationGuidancePolicy.shouldSuppressArrival(
                            location: selectionLocation, station: stations.first { $0.id == old.originId }?.location,
                            now: now) ? old.originId : nil)
        }
    }

    @discardableResult
    static func selectStationDepartures(expectedRevision: Int, originId: String, destinationId: String,
                                        stations: [Station], selectionLocation: CLLocation? = nil,
                                        automatic: Bool = false,
                                        now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision, originId != destinationId,
                  stations.contains(where: { $0.id == originId }),
                  let destination = stations.first(where: { $0.id == destinationId }) else { return }
            // Explicit station departures change the active route, not the saved endpoints.
            route = Route(originId: originId, destinationId: destinationId,
                          savedOriginId: old.savedOriginId, savedDestinationId: old.savedDestinationId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.stationSelection.rawValue, manual: automatic ? old.manual : true,
                          blockedArrivalDestinationId: LocationGuidancePolicy.shouldSuppressArrival(
                            location: selectionLocation, station: destination.location, now: now) ? destinationId : nil)
            route?.temporaryRoute = old.temporaryRoute ?? TemporaryRoute(
                originId: old.originId, destinationId: old.destinationId, manual: old.manual)
            if destinationId == old.destinationId {
                route?.arrivalGate = old.arrivalGate
                route?.journeySelectedAt = old.journeySelectedAt ?? old.updatedAt
                route?.returnDirectionEvidence = old.returnDirectionEvidence
            }
        }
    }

    static func restoreStationRoute(expectedRevision: Int, departureLocation: CLLocation? = nil,
                                    requireDeparture: Bool = false, stations: [Station] = [],
                                    now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision, let original = old.temporaryRoute else { return }
            if requireDeparture {
                guard let departureLocation, let station = stations.first(where: { $0.id == old.originId }),
                      departureLocation.timestamp > old.updatedAt,
                      LocationGuidancePolicy.hasLeftStation(departureLocation, station: station.location, now: now) else { return }
            }
            route = Route(originId: original.originId, destinationId: original.destinationId,
                          savedOriginId: old.savedOriginId, savedDestinationId: old.savedDestinationId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.stationRestored.rawValue, manual: original.manual,
                          blockedArrivalDestinationId: original.destinationId == old.destinationId ? old.blockedArrivalDestinationId : nil,
                          arrivalGate: original.destinationId == old.destinationId ? old.arrivalGate : nil,
                          journeySelectedAt: original.destinationId == old.destinationId ? old.journeySelectedAt ?? old.updatedAt : nil)
            if original.destinationId == old.destinationId {
                route?.returnDirectionEvidence = old.returnDirectionEvidence
            }
        }
    }

    @discardableResult
    static func recoverReturnDirection(expectedRevision: Int, location: CLLocation?, stations: [Station],
                                       now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  let origin = stations.first(where: { $0.id == old.savedOriginId }),
                  let destination = stations.first(where: { $0.id == old.destinationId }),
                  origin.id != destination.id else { return }
            var evidence = old.returnDirectionEvidence ?? ReturnDirectionEvidence()
            guard let location else {
                if destination.supportsUndergroundReturnRecovery {
                    evidence.resetUndergroundCandidate()
                    route?.returnDirectionEvidence = evidence
                } else {
                    route?.returnDirectionEvidence = nil
                }
                return
            }
            let recovered = evidence.accepts(location: location, origin: origin.location,
                destination: destination.location, selectedAt: old.journeySelectedAt ?? old.updatedAt, now: now,
                undergroundDestination: destination.supportsUndergroundReturnRecovery ? destination : nil, stations: stations)
            route?.returnDirectionEvidence = evidence
            if directory == nil, let diagnostic = evidence.undergroundDiagnostic,
               diagnostic != old.returnDirectionEvidence?.undergroundDiagnostic {
                ArrivalDiagnostics.record("Underground return recovery", detail: "\(destination.name): \(diagnostic)")
            }
            guard recovered, old.blockedArrivalDestinationId == nil else { return }
            let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: destination.id,
                currentOrigin: old.originId, savedOrigin: old.savedOriginId, savedDestination: old.savedDestinationId)
            guard returnId != destination.id else { return }
            route = Route(originId: destination.id, destinationId: returnId,
                savedOriginId: destination.id, savedDestinationId: returnId,
                revision: old.revision + 1, updatedAt: now, lastLocationAt: location.timestamp,
                reason: JourneyRouteEvent.recovery.rawValue, manual: false)
        }
    }

    static func checkArrival(expectedRevision: Int, location: CLLocation?, stations: [Station],
                             now: Date = Date(), directory: URL? = nil,
                             expectedArrival: Date? = nil) -> DestinationArrivalGate? {
        var result: DestinationArrivalGate?
        _ = transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision else { return }
            guard let location else {
                route?.arrivalGate?.resetEvidence()
                return
            }
            guard
                  let destination = stations.first(where: { $0.id == old.destinationId }),
                  let origin = stations.first(where: { $0.id == old.savedOriginId }) else { return }
            var gate = old.arrivalGate ?? DestinationArrivalGate()
            gate.expectedArrival = expectedArrival ?? (old.journey?.isActive(at: now) == true ? old.journey?.arrival : nil)
            if location.horizontalAccuracy <= 75,
               let station = LocationGuidancePolicy.detectedStation(location, stations: stations, now: now),
               station.id != destination.id {
                gate.invalidateDestinationEvidence(location: location)
            }
            let selectedAt = old.journeySelectedAt ?? old.updatedAt
            gate.observeJourney(origin: origin.location, destination: destination.location,
                                location: location, selectedAt: selectedAt, now: now)
            gate.observeDeparture(from: destination.location, location: location, now: now)
            let otherDistance = stations.filter { $0.id != destination.id }
                .map { location.distance(from: $0.location) }.min() ?? .infinity
            _ = gate.accepts(destinationId: destination.id, station: destination.location,
                             location: location, nearestOtherStationDistance: otherDistance,
                             routeSelectedAt: selectedAt, now: now,
                             undergroundDestination: destination.supportsUndergroundReturnRecovery,
                             arrivalSuppressed: old.blockedArrivalDestinationId == destination.id)
            route?.arrivalGate = gate
            result = gate
        }
        return result
    }

    @discardableResult
    static func selectNearestStation(expectedRevision: Int, location: CLLocation,
                                     stations: [Station], now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  old.endpointStations(in: stations).count == 2,
                  let nearest = LocationGuidancePolicy.nearestUnambiguousStation(location,
                    stations: old.endpointStations(in: stations), now: now) else { return }
            // The compass chooses direction, never a new route endpoint.
            let destinationId = nearest.id == old.savedOriginId ? old.savedDestinationId : old.savedOriginId
            guard destinationId != nearest.id,
                  let destination = stations.first(where: { $0.id == destinationId }) else { return }
            route = Route(originId: nearest.id, destinationId: destinationId,
                          savedOriginId: nearest.id, savedDestinationId: destinationId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: location.timestamp,
                          reason: JourneyRouteEvent.nearest.rawValue, manual: true,
                          blockedArrivalDestinationId: LocationGuidancePolicy.shouldSuppressArrival(
                            location: location, station: destination.location, now: now) ? destinationId : nil)
        }
    }

    @discardableResult
    static func routeForApp(defaultOriginId: String, defaultDestinationId: String,
                            now: Date = Date(), directory: URL? = nil) -> Route? {
        // Refreshing local UI is not a route selection. Bootstrap only when nothing is persisted.
        current(directory: directory) ?? commit(originId: defaultOriginId, destinationId: defaultDestinationId,
                                               now: now, directory: directory)
    }

    @discardableResult
    static func commit(originId: String, destinationId: String, manual: Bool = false,
                       expectedRevision: Int? = nil, arrival: Bool = false,
                       observationAt: Date? = nil,
                       selectionLocation: CLLocation? = nil, destinationLocation: CLLocation? = nil,
                       now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard originId != destinationId else { return }
            if !manual, let old = route, old.revision != expectedRevision { return }
            // Fresh GPS must not undo an explicit route choice from another surface.
            if !manual, !arrival, route?.manual == true { return }
            if !manual, let old = route, old.originId == originId, old.destinationId == destinationId { return }
            if !manual, let old = route, let observationAt, observationAt <= old.updatedAt { return }
            if arrival, route?.blockedArrivalDestinationId != nil { return }
            let old = route
            route = Route(originId: originId, destinationId: destinationId,
                          savedOriginId: manual || arrival ? originId : old?.savedOriginId ?? originId,
                          savedDestinationId: manual || arrival ? destinationId : old?.savedDestinationId ?? destinationId,
                          revision: (old?.revision ?? 0) + 1, updatedAt: now, lastLocationAt: old?.lastLocationAt,
                          reason: (manual ? JourneyRouteEvent.selection : arrival ? .appArrival : .bootstrap).rawValue,
                          manual: manual || (!arrival && old?.manual == true),
                          blockedArrivalDestinationId: manual
                            ? (LocationGuidancePolicy.shouldSuppressArrival(location: selectionLocation,
                                station: destinationLocation, now: now) ? destinationId : nil)
                            : (arrival ? nil : old?.blockedArrivalDestinationId))
        }
    }

    static func confirmTripArrival(originId: String, destinationId: String, expectedRevision: Int,
                                   now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  old.destinationId == destinationId,
                  (old.originId == originId || old.temporaryRoute?.originId == originId),
                  originId != destinationId else { return }
            route = Route(originId: destinationId, destinationId: originId,
                          savedOriginId: destinationId, savedDestinationId: originId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.confirmedArrival.rawValue, manual: false)
        }
    }

    static func resolve(location: CLLocation?, stations: [Station], now: Date = Date(), directory: URL? = nil,
                        onArrivalCheck: ((DestinationArrivalGate) -> Void)? = nil,
                        expectedArrival: Date? = nil) -> Route? {
        transaction(directory: directory) { route in
            clearArrivalSuppressionIfDeparted(route: &route, location: location, stations: stations, now: now)
            if location == nil { route?.arrivalGate?.resetEvidence() }
            guard let old = route, let location,
                  let station = stations.first(where: { $0.id == old.destinationId }) else { return }
            var gate = old.arrivalGate ?? DestinationArrivalGate()
            if let expectedArrival = expectedArrival ?? (old.journey?.isActive(at: now) == true ? old.journey?.arrival : nil) {
                gate.expectedArrival = expectedArrival
            }
            if let origin = stations.first(where: { $0.id == old.savedOriginId }) {
                gate.observeJourney(origin: origin.location, destination: station.location, location: location,
                                    selectedAt: old.journeySelectedAt ?? old.updatedAt, now: now)
            }
            let otherDistance = stations.filter { $0.id != station.id }.map { location.distance(from: $0.location) }.min() ?? .infinity
            let arrived = gate.accepts(destinationId: station.id, station: station.location, location: location,
                nearestOtherStationDistance: otherDistance, routeSelectedAt: old.journeySelectedAt ?? old.updatedAt,
                now: now, undergroundDestination: station.supportsUndergroundReturnRecovery,
                arrivalSuppressed: old.blockedArrivalDestinationId != nil)
            onArrivalCheck?(gate)
            if old.arrivalGate != nil || gate.hasArrivalEvidence { route?.arrivalGate = gate }
            guard arrived else { return }
            let destination = SharedWidgetRouteMemory.returnDestination(arrivingAt: station.id, currentOrigin: old.originId,
                savedOrigin: old.savedOriginId, savedDestination: old.savedDestinationId)
            guard destination != station.id else { return }
            route = Route(originId: station.id, destinationId: destination,
                          savedOriginId: station.id, savedDestinationId: destination,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: location.timestamp,
                          reason: (gate.usedNearestStationFallback ? JourneyRouteEvent.estimatedArrival : .backgroundArrival).rawValue, manual: false)
        }
    }

    static func resolveWidgetRoute(location: CLLocation?, stations: [Station], now: Date = Date(), directory: URL? = nil,
                                   onArrivalCheck: ((DestinationArrivalGate) -> Void)? = nil,
                                   expectedArrival: Date? = nil) -> Route? {
        let previousRevision = current(directory: directory)?.revision
        guard let resolved = resolve(location: location, stations: stations, now: now, directory: directory,
                                     onArrivalCheck: onArrivalCheck, expectedArrival: expectedArrival) else { return nil }
        // Confirmed arrival or a concurrent selection takes precedence over direction recovery.
        guard resolved.revision == previousRevision else { return resolved }
        return recoverReturnDirection(expectedRevision: resolved.revision, location: location,
            stations: stations, now: now, directory: directory) ?? resolved
    }

    static func observeDeparture(location: CLLocation, stations: [Station], now: Date = Date(), directory: URL? = nil) {
        _ = transaction(directory: directory) { route in
            clearArrivalSuppressionIfDeparted(route: &route, location: location, stations: stations, now: now)
        }
    }

    static func selectedStations(in stations: [Station], directory: URL? = nil) -> (origin: Station, destination: Station)? {
        guard let route = current(directory: directory),
              let origin = stations.first(where: { $0.id == route.originId }),
              let destination = stations.first(where: { $0.id == route.destinationId }),
              origin.id != destination.id else { return nil }
        return (origin, destination)
    }

    private static func clearArrivalSuppressionIfDeparted(route: inout Route?, location: CLLocation?, stations: [Station], now: Date) {
        guard let old = route, let blocked = old.blockedArrivalDestinationId,
              let location, location.timestamp > old.updatedAt,
              old.lastLocationAt.map({ location.timestamp > $0 }) ?? true,
              LocationGuidancePolicy.isUsable(location, maxAge: 30, now: now),
              let station = stations.first(where: { $0.id == blocked }),
              location.distance(from: station.location) - location.horizontalAccuracy > 150 else { return }
        route?.blockedArrivalDestinationId = nil
        route?.lastLocationAt = location.timestamp
    }

    private static func transaction(directory: URL?, change: (inout Route?) -> Void) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        // Never create per-extension fallbacks: they would become competing route authorities.
        guard let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.rhome.patconext") else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let descriptor = open(root.appendingPathComponent("route.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return nil }
            defer { flock(descriptor, LOCK_UN) }
            let file = root.appendingPathComponent("resolved-route.json")
            var route = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Route.self, from: $0) }
            let previous = route
            change(&route)
            if let old = previous, let next = route, next.revision != old.revision {
                route?.journey = old.journey
                route?.journeyProgress = old.journeyProgress
                if let session = old.journey, !session.completed, session.termination == nil {
                    if next.completesJourney {
                        route?.journey?.completed = true
                        route?.journey?.termination = .arrived
                    } else if next.event.endsTracking || next.destinationId != old.destinationId || (!next.event.isTemporary
                        && (next.savedOriginId != old.savedOriginId || next.savedDestinationId != old.savedDestinationId)) {
                        route?.journey?.termination = .cancelled
                    }
                }
            }
            if route != previous, let route {
                try JSONEncoder().encode(route).write(to: file, options: .atomic)
                if directory == nil, (route.revision != previous?.revision && route.endsJourneyTracking)
                    || (route.journey?.termination != nil && route.journey?.termination != previous?.journey?.termination) {
                    SharedJourneyTracking.end()
                }
                if directory == nil, route.revision != previous?.revision {
                    ArrivalDiagnostics.record("Route changed", detail:
                        "Revision \(previous?.revision ?? 0) -> \(route.revision); "
                        + "\(previous?.originId ?? "none") to \(previous?.destinationId ?? "none") -> "
                        + "\(route.originId) to \(route.destinationId); reason: \(route.reason); "
                        + "temporary station route: \(route.temporaryRoute != nil)")
                }
                if directory == nil, route.revision != previous?.revision
                    || route.blockedArrivalDestinationId != previous?.blockedArrivalDestinationId {
                    SharedWidgetDiagnostics.record("Route decision", detail:
                        "Revision \(route.revision): \(route.originId) to \(route.destinationId); \(route.reason); "
                        + (route.blockedArrivalDestinationId.map { "arrival suppressed at \($0) until departure" }
                            ?? "arrival not suppressed"))
                }
            }
            return route
        } catch {
            return nil
        }
    }
}

struct DestinationArrivalGate: Codable, Equatable {
    var hasStopEvidence: Bool { stopEvidence != nil }
    var hasArrivalEvidence: Bool { hasStopEvidence || geofenceOutsideAt != nil || journeyAnchorAt != nil }
    private(set) var lastDecision = "No arrival reading yet"
    private(set) var usedNearestStationFallback = false
    private(set) var confirmed = false
    private var journeyAnchorDistance: Double?
    private var journeyAnchorAt: Date?
    private var journeyProgressAt: Date?
    private var lastObservationAt: Date?
    private var blockedDestination: Station.ID?
    private var candidate: Station.ID?
    private var firstFix: Date?
    private var fallbackDestination: Station.ID?
    private var fallbackFix: Date?
    private var stopEvidence: StationStopEvidence?
    private var preciseStopEvidence: StationStopEvidence?
    private var geofenceOutsideAt: Date?
    private var estimatedFirstAt: Date?
    private var estimatedLastAt: Date?
    private var estimatedReadingCount: Int?
    private var estimatedDestinationId: Station.ID?
    var expectedArrival: Date?

    func diagnosticDescription(for location: CLLocation, now: Date = Date()) -> String {
        guard let stopEvidence else { return lastDecision }
        let standard = lastDecision + "; " + stopEvidence.diagnosticDescription(for: location, now: now)
        guard let preciseStopEvidence else { return standard }
        return standard + "; precise arrival: " + preciseStopEvidence.diagnosticDescription(for: location, now: now, preciseArrival: true)
    }

    mutating func observeJourney(origin: CLLocation, destination: CLLocation, location: CLLocation,
                                selectedAt: Date, now: Date = Date()) {
        guard lastObservationAt.map({ location.timestamp > $0 }) ?? true,
              location.timestamp > selectedAt,
              LocationGuidancePolicy.isUsable(location, maxAge: 30, now: now),
              location.horizontalAccuracy <= 75 else { return }
        let distance = location.distance(from: destination)
        guard location.distance(from: origin) + distance <= origin.distance(from: destination) + 1000 else { return }
        if let anchor = journeyAnchorDistance, let anchorAt = journeyAnchorAt,
           location.timestamp > anchorAt,
           journeyProgressAt.map({ location.timestamp > $0 }) ?? true,
           distance + 300 <= anchor {
            journeyProgressAt = location.timestamp
        } else if journeyAnchorDistance == nil, distance > 900,
                  location.distance(from: origin) + 500 < distance {
            journeyAnchorDistance = distance
            journeyAnchorAt = location.timestamp
        }
    }

    mutating func resetEvidence() {
        confirmed = false
        stopEvidence = nil
        preciseStopEvidence = nil
        candidate = nil
        firstFix = nil
        fallbackDestination = nil
        fallbackFix = nil
        estimatedFirstAt = nil
        estimatedLastAt = nil
        estimatedReadingCount = nil
        estimatedDestinationId = nil
    }

    mutating func invalidateDestinationEvidence(location: CLLocation) {
        guard lastObservationAt.map({ location.timestamp > $0 }) ?? true else { return }
        resetEvidence()
    }

    mutating func prepareSelection(destinationId: Station.ID, station: CLLocation, location: CLLocation, now: Date = Date()) {
        self = Self()
        if LocationGuidancePolicy.shouldSuppressArrival(location: location, station: station, now: now) {
            blockedDestination = destinationId
        }
    }

    mutating func observeDeparture(from station: CLLocation, location: CLLocation, now: Date = Date()) {
        guard lastObservationAt.map({ location.timestamp > $0 }) ?? true,
              LocationGuidancePolicy.isUsable(location, maxAge: 30, now: now),
              CLLocationCoordinate2DIsValid(station.coordinate) else { return }
        if location.distance(from: station) - location.horizontalAccuracy > 150 {
            blockedDestination = nil
            candidate = nil
            firstFix = nil
            stopEvidence = nil
            preciseStopEvidence = nil
        }
    }

    mutating func accepts(destinationId: Station.ID, station: CLLocation, location: CLLocation,
                          nearestOtherStationDistance: Double = .infinity, routeSelectedAt: Date? = nil,
                          now: Date = Date(), undergroundDestination: Bool = false,
                          arrivalSuppressed: Bool = false) -> Bool {
        usedNearestStationFallback = false
        confirmed = false
        // Cached replays cannot extend or erase a stop, even after that fix becomes stale.
        guard lastObservationAt.map({ location.timestamp > $0 }) ?? true else {
            lastDecision = location.timestamp == lastObservationAt
                ? "Duplicate location reading" : "Out-of-order location reading"
            return false
        }
        guard CLLocationCoordinate2DIsValid(location.coordinate), CLLocationCoordinate2DIsValid(station.coordinate) else {
            lastDecision = "Invalid location coordinate"
            stopEvidence = nil
            preciseStopEvidence = nil
            estimatedFirstAt = nil
            estimatedLastAt = nil
            estimatedReadingCount = nil
            estimatedDestinationId = nil
            return false
        }
        let distance = location.distance(from: station)
        // A fresh outside-to-inside crossing confirms arrival without any speed or dwell requirement.
        // Retain the outside observation through tunnel gaps, but not indefinitely.
        if LocationGuidancePolicy.isUsable(location, maxAge: 15, now: now),
           location.horizontalAccuracy <= 50,
           routeSelectedAt.map({ location.timestamp > $0 }) ?? true,
           distance - location.horizontalAccuracy > LocationGuidancePolicy.stationRadiusMeters {
            geofenceOutsideAt = location.timestamp
        }
        if (0...60).contains(now.timeIntervalSince(location.timestamp)) {
            lastObservationAt = location.timestamp
        }
        // Underground fixes cannot prove a station boundary crossing. Infer arrival only
        // after reliable journey progress followed by sustained, unambiguous proximity.
        if undergroundDestination, !arrivalSuppressed, blockedDestination != destinationId,
           routeSelectedAt.map({ location.timestamp > $0 }) ?? true,
           (0...15).contains(now.timeIntervalSince(location.timestamp)),
           location.horizontalAccuracy.isFinite, (50...2000).contains(location.horizontalAccuracy),
           distance <= UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy),
           nearestOtherStationDistance - distance >= 150,
           expectedArrival.map({ UrbanStationArrivalPolicy.isNearScheduledArrival($0, now: now) }) ?? true,
           location.speed.isFinite, location.speed < 0 || location.speed <= 2,
           let progressAt = journeyProgressAt,
           (0...20 * 60).contains(location.timestamp.timeIntervalSince(progressAt)),
           let anchorDistance = journeyAnchorDistance, anchorDistance >= distance + 900 {
            let gap = estimatedLastAt.map { location.timestamp.timeIntervalSince($0) }
            let resetReason: String?
            if estimatedDestinationId != destinationId || estimatedReadingCount == nil {
                resetReason = "new destination evidence"
            } else if gap.map({ $0 > UrbanStationArrivalPolicy.destinationMaximumReadingGap }) ?? true {
                resetReason = "reading gap exceeded 90 sec"
            } else {
                resetReason = nil
            }
            // Only a new qualifying fix can confirm arrival; silence never advances evidence.
            if resetReason != nil {
                estimatedFirstAt = location.timestamp
                estimatedReadingCount = 0
            }
            estimatedDestinationId = destinationId
            estimatedReadingCount = (estimatedReadingCount ?? 0) + 1
            estimatedLastAt = location.timestamp
            stopEvidence = nil
            preciseStopEvidence = nil
            confirmed = estimatedFirstAt.map {
                location.timestamp.timeIntervalSince($0) >= UrbanStationArrivalPolicy.destinationConfirmationSeconds
            } ?? false
            usedNearestStationFallback = confirmed
            let elapsed = location.timestamp.timeIntervalSince(estimatedFirstAt ?? location.timestamp)
            let evidenceDetail = "\(estimatedReadingCount ?? 0) distinct readings; span \(Int(elapsed)) sec; required \(Int(UrbanStationArrivalPolicy.destinationConfirmationSeconds)) sec; last gap \(Int(gap ?? 0)) sec"
            lastDecision = (confirmed ? "Estimated arrival: sustained underground destination readings after reliable journey progress"
                : "Estimated arrival pending") + "; " + evidenceDetail
                + (resetReason.map { "; evidence restarted: \($0)" } ?? "")
            return confirmed
        }
        let hadEstimatedEvidence = estimatedFirstAt != nil
        let undergroundReason: String
        if !undergroundDestination { undergroundReason = "destination is not underground" }
        else if arrivalSuppressed || blockedDestination == destinationId { undergroundReason = "arrival suppressed until departure" }
        else if !(routeSelectedAt.map({ location.timestamp > $0 }) ?? true) { undergroundReason = "reading predates route selection" }
        else if !(0...15).contains(now.timeIntervalSince(location.timestamp)) { undergroundReason = "stale or future-dated reading" }
        else if !location.horizontalAccuracy.isFinite || !(50...2000).contains(location.horizontalAccuracy) { undergroundReason = "accuracy outside underground range 50...2000 m" }
        else if distance > UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy) { undergroundReason = "outside destination proximity radius" }
        else if nearestOtherStationDistance - distance < 150 { undergroundReason = "ambiguous neighboring station" }
        else if !(expectedArrival.map({ UrbanStationArrivalPolicy.isNearScheduledArrival($0, now: now) }) ?? true) { undergroundReason = "outside scheduled arrival window" }
        else if !location.speed.isFinite || location.speed > 2 { undergroundReason = "speed exceeds underground limit or is invalid" }
        else if !(journeyProgressAt.map({ (0...20 * 60).contains(location.timestamp.timeIntervalSince($0)) }) ?? false) { undergroundReason = "reliable journey progress missing or expired" }
        else { undergroundReason = "insufficient distance progressed from journey anchor" }
        estimatedFirstAt = nil
        estimatedLastAt = nil
        estimatedReadingCount = nil
        estimatedDestinationId = nil
        let rejection: String?
        if blockedDestination == destinationId || arrivalSuppressed {
            rejection = "Destination selected while already nearby; waiting for departure"
        } else if let routeSelectedAt, location.timestamp <= routeSelectedAt {
            rejection = "Reading predates route selection"
        } else if !(0...15).contains(now.timeIntervalSince(location.timestamp)) {
            rejection = "Reading stale (over 15 sec) or future-dated"
        } else if !location.horizontalAccuracy.isFinite || location.horizontalAccuracy <= 0 || location.horizontalAccuracy > 50 {
            rejection = "Accuracy invalid or worse than 50 m"
        } else if distance + location.horizontalAccuracy > LocationGuidancePolicy.stationRadiusMeters {
            rejection = "Uncertainty circle outside 150 m station boundary"
        } else if nearestOtherStationDistance - distance < max(75, 2 * location.horizontalAccuracy) {
            rejection = "Ambiguous neighboring station (distance advantage under 75 m)"
        } else if let outsideAt = geofenceOutsideAt,
                  location.timestamp > outsideAt, location.timestamp.timeIntervalSince(outsideAt) <= 90 * 60 {
            confirmed = true
            stopEvidence = nil
            preciseStopEvidence = nil
            lastDecision = "Destination geofence entered; no stop required"
            return true
        } else if !location.speed.isFinite || location.speed < 0 || location.speed > 0.5 {
            rejection = "Stopped motion not established by location speed"
        } else {
            rejection = nil
        }
        if let rejection {
            lastDecision = "Precise GPS arrival rejected: " + rejection
                + (hadEstimatedEvidence ? "; underground estimate reset: " : "; underground estimate not eligible: ") + undergroundReason
            candidate = nil
            firstFix = nil
            stopEvidence = nil
            preciseStopEvidence = nil
            return false
        }
        var evidence = stopEvidence ?? StationStopEvidence()
        let standardConfirmed = evidence.accepts(stationId: destinationId, station: station, location: location,
            nearestOtherDistance: nearestOtherStationDistance, now: now)
        stopEvidence = evidence
        var precise = preciseStopEvidence ?? StationStopEvidence()
        let preciseConfirmed = precise.accepts(stationId: destinationId, station: station, location: location,
            nearestOtherDistance: nearestOtherStationDistance, now: now, preciseArrival: true)
        preciseStopEvidence = precise
        let confirmed = standardConfirmed || preciseConfirmed
        lastDecision = preciseConfirmed ? "Confirmed precise destination stop spanning 5 sec"
            : standardConfirmed ? "Confirmed reliable stopped destination readings"
            : "Waiting for a precise 5-sec stop or reliable stopped readings spanning 10 sec"
        self.confirmed = confirmed
        return confirmed
    }
}

struct PATCOFeed: Codable {
    let generatedFrom: String
    let feed: [String: String]
    let route: [String: String]
    let stops: [Station]
    let calendars: [ServiceCalendar]
    let calendarDates: [CalendarDateException]
    let trips: [Trip]

    func validateStopIdentifiers() throws {
        let ids = stops.map(\.id)
        guard !ids.isEmpty,
              ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(ids).count == ids.count else {
            throw ScheduleLoadError.invalidStopIdentifiers
        }
    }
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

    var defaultsToWalkingForReachability: Bool {
        zone == "6"
    }

    var supportsUndergroundReturnRecovery: Bool {
        // PATCO's Camden and Philadelphia underground city stops, using bundled feed codes.
        ["8", "9", "10", "11", "12", "13", "14"].contains(code)
    }
}

struct DepartureDeepLink: Equatable {
    let originId: Station.ID
    let destinationId: Station.ID
    let departureDate: Date

    init?(url: URL) {
        guard url.scheme == "patconext", url.host == "departure",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let originId = components.queryItems?.first(where: { $0.name == "origin" })?.value,
              let destinationId = components.queryItems?.first(where: { $0.name == "destination" })?.value,
              !originId.isEmpty, !destinationId.isEmpty, originId != destinationId,
              let departureValue = components.queryItems?.first(where: { $0.name == "departure" })?.value,
              let departureTimeInterval = TimeInterval(departureValue), departureTimeInterval.isFinite else { return nil }
        self.originId = originId
        self.destinationId = destinationId
        departureDate = Date(timeIntervalSince1970: departureTimeInterval)
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

struct Departure: Identifiable, Codable {
    var id = UUID()
    let trip: Trip
    let origin: Station
    let destination: Station
    let originTime: StopTime
    let destinationTime: StopTime
    let serviceDate: Date
    let departureDate: Date
    let arrivalDate: Date
    let routeSequenceIndex: Int
    let isSpecialSchedule: Bool
    let isRemovedBySpecialSchedule: Bool
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
            isSpecialSchedule: isSpecialSchedule,
            isRemovedBySpecialSchedule: isRemovedBySpecialSchedule,
            scheduleAdjustment: adjustment
        )
    }

    func markedRemovedBySpecialSchedule(routeSequenceIndex: Int) -> Departure {
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
            isSpecialSchedule: true,
            isRemovedBySpecialSchedule: true,
            scheduleAdjustment: nil
        )
    }
}

struct ScheduleAdjustment: Codable {
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

    var hasUnconfirmedTimes: Bool {
        trips.contains { trip in
            trip.stopTimes.contains { !$0.isEmpty && PATCOScheduleStore.scheduleDate(
                serviceDate: serviceDate, timeString: $0, isSpecialSchedule: true) == nil }
        }
    }

    func hasUnconfirmedTimes(on date: Date) -> Bool {
        guard hasUnconfirmedTimes else { return false }
        let calendar = PATCOClock.calendar
        if calendar.isDate(serviceDate, inSameDayAs: date) { return true }
        return trips.contains { trip in
            trip.stopTimes.contains { time in
                guard let hourText = time.split(separator: ":").first, let hours = Int(hourText), hours >= 0,
                      let day = calendar.date(byAdding: .day, value: hours / 24, to: calendar.startOfDay(for: serviceDate)),
                      calendar.isDate(day, inSameDayAs: date) else { return false }
                return PATCOScheduleStore.scheduleDate(serviceDate: serviceDate, timeString: time, isSpecialSchedule: true) == nil
            }
        }
    }
}

struct ActiveSpecialSchedule: Equatable {
    let title: String
    let serviceDate: Date
    let sourceURL: URL
    let tripCount: Int
    var hasUnconfirmedTimes: Bool = false
}

enum ScheduleLoadError: LocalizedError {
    case missingResource
    case invalidStopIdentifiers

    var errorDescription: String? {
        switch self {
        case .missingResource: "The bundled PATCO schedule could not be loaded."
        case .invalidStopIdentifiers: "The PATCO schedule contains invalid or duplicate station identifiers."
        }
    }
}

struct PATCOFeedMetadata: Codable {
    let downloadedAt: Date
    let feedStartDate: String
    let feedEndDate: String
    let feedVersion: String?
    let lastUpdatedAt: Date?
    let previousFeedVersion: String?
    let sourceURL: URL
}

enum PATCOFeedCache {
    private static let appGroup = "group.com.rhome.patconext"
    private static let scheduleDirectory = "Schedules"
    private static let feedFilename = "patco_schedule.json"
    private static let metadataFilename = "metadata.json"

    static func load() -> PATCOFeed? {
        guard let data = try? Data(contentsOf: feedURL) else { return nil }
        return try? decodeValidatedFeed(data)
    }

    static func decodeValidatedFeed(_ data: Data) throws -> PATCOFeed {
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: data)
        try feed.validateStopIdentifiers()
        return feed
    }

    static func loadMetadata() -> PATCOFeedMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PATCOFeedMetadata.self, from: data)
    }

    static func save(_ feed: PATCOFeed, metadata: PATCOFeedMetadata) throws {
        try feed.validateStopIdentifiers()
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
              let expirationDate = PATCOClock.calendar.date(
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
    @Published private(set) var feedMetadata: PATCOFeedMetadata?

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
        var routeDistanceMeters: Double? = nil
        var requestStartedAt: Date? = nil

        func isValid(for origin: Station, currentLocation: CLLocation,
                     mode: Mode? = nil, now: Date = Date()) -> Bool {
            let movementLimit: CLLocationDistance
            switch mode {
            case .walking: movementLimit = 50
            case .driving: movementLimit = 100
            case nil: movementLimit = 250
            }
            return originId == origin.id
                && (0..<5 * 60).contains(now.timeIntervalSince(fetchedAt))
                && sourceLocation.distance(from: currentLocation) < movementLimit
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

    @discardableResult
    static func save(mode: Mode, origin: Station, currentLocation: CLLocation, minutes: Int, fetchedAt: Date = Date(), routeDistanceMeters: Double? = nil,
                     requestStartedAt: Date? = nil, defaults suppliedDefaults: UserDefaults? = nil, directory: URL? = nil) -> Bool {
        let defaults = suppliedDefaults ?? self.defaults
        let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        guard let root else { return false }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("travel-estimate.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        if let data = defaults.data(forKey: key(for: mode)),
           let existing = try? JSONDecoder().decode(Estimate.self, from: data) {
            if let requestStartedAt {
                if (existing.requestStartedAt ?? existing.fetchedAt) > requestStartedAt { return false }
            } else if existing.fetchedAt > fetchedAt {
                return false
            }
        }
        let estimate = Estimate(
            originId: origin.id,
            sourceLatitude: currentLocation.coordinate.latitude,
            sourceLongitude: currentLocation.coordinate.longitude,
            minutes: minutes,
            fetchedAt: fetchedAt,
            routeDistanceMeters: routeDistanceMeters,
            requestStartedAt: requestStartedAt
        )

        if let data = try? JSONEncoder().encode(estimate) {
            defaults.set(data, forKey: key(for: mode))
            return true
        }
        return false
    }

    static func estimate(mode: Mode, origin: Station, currentLocation: CLLocation) -> Estimate? {
        guard let data = defaults.data(forKey: key(for: mode)),
              let estimate = try? JSONDecoder().decode(Estimate.self, from: data),
              estimate.isValid(for: origin, currentLocation: currentLocation, mode: mode) else {
            return nil
        }

        return estimate
    }

    @discardableResult
    static func clear(mode: Mode, ifNotNewerThan requestStartedAt: Date? = nil,
                      originId: Station.ID? = nil, defaults suppliedDefaults: UserDefaults? = nil,
                      directory: URL? = nil) -> Bool {
        let defaults = suppliedDefaults ?? self.defaults
        let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        guard let root else { return false }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("travel-estimate.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        if let requestStartedAt {
            guard let data = defaults.data(forKey: key(for: mode)),
                  let existing = try? JSONDecoder().decode(Estimate.self, from: data),
                  originId == nil || existing.originId == originId,
                  existing.fetchedAt <= requestStartedAt,
                  (existing.requestStartedAt ?? existing.fetchedAt) <= requestStartedAt else { return false }
        }
        defaults.removeObject(forKey: key(for: mode))
        return true
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

enum LockScreenRefreshFeedback {
    private struct Completion: Codable {
        let id: UUID
        var visibleUntil: Date?
    }

    private static let key = "lockScreenRefreshCompletion"
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard
    }

    static func recordCompletion(defaults: UserDefaults? = nil) {
        let completion = Completion(id: UUID(), visibleUntil: nil)
        if let data = try? JSONEncoder().encode(completion) {
            (defaults ?? sharedDefaults).set(data, forKey: key)
        }
    }

    static func visibleUntil(at now: Date, defaults: UserDefaults? = nil) -> Date? {
        let storage = defaults ?? sharedDefaults
        guard let data = storage.data(forKey: key),
              var completion = try? JSONDecoder().decode(Completion.self, from: data) else { return nil }
        if let end = completion.visibleUntil { return end > now ? end : nil }
        // Start the confirmation window when a timeline is prepared, not when the tap occurred.
        let end = now.addingTimeInterval(3)
        completion.visibleUntil = end
        if let encoded = try? JSONEncoder().encode(completion) { storage.set(encoded, forKey: key) }
        return end
    }
}

enum SharedWidgetReachabilityState {
    struct PendingRefresh: Codable, Equatable {
        let id: UUID
        let originId: Station.ID
        let mode: SharedReachabilityModeStore.Mode
    }

    private static let key = "widgetReachabilityPendingRefresh"
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard
    }

    static func pending(defaults: UserDefaults? = nil) -> PendingRefresh? {
        guard let data = (defaults ?? sharedDefaults).data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingRefresh.self, from: data)
    }

    static func requireRefresh(originId: Station.ID, mode: SharedReachabilityModeStore.Mode,
                               defaults: UserDefaults? = nil) {
        let request = PendingRefresh(id: UUID(), originId: originId, mode: mode)
        guard let data = try? JSONEncoder().encode(request) else { return }
        (defaults ?? sharedDefaults).set(data, forKey: key)
    }

    static func needsFollowUpRefresh(after request: PendingRefresh?, defaults: UserDefaults? = nil) -> Bool {
        guard let current = pending(defaults: defaults) else { return false }
        return current.id != request?.id
    }

    static func reconcileMode(originId: Station.ID, mode: SharedReachabilityModeStore.Mode,
                              defaults: UserDefaults? = nil) {
        guard let request = pending(defaults: defaults), request.originId == originId,
              request.mode != mode else { return }
        requireRefresh(originId: originId, mode: mode, defaults: defaults)
    }

    static func blocksCatchability(originId: Station.ID, defaults: UserDefaults? = nil) -> Bool {
        pending(defaults: defaults)?.originId == originId
    }

    @discardableResult
    static func complete(_ request: PendingRefresh, defaults: UserDefaults? = nil) -> Bool {
        // A refresh for an earlier toggle must not unlock the newly selected mode.
        guard pending(defaults: defaults) == request else { return false }
        (defaults ?? sharedDefaults).removeObject(forKey: key)
        return true
    }

    @discardableResult
    static func completeIfReady(_ request: PendingRefresh, originId: Station.ID,
                                mode: SharedReachabilityModeStore.Mode?, hasFreshEstimate: Bool,
                                isAtStation: Bool, defaults: UserDefaults? = nil) -> Bool {
        guard request.originId == originId,
              isAtStation || (request.mode == mode && hasFreshEstimate) else { return false }
        return complete(request, defaults: defaults)
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
        var usesWalkingRoute: Bool? = nil
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let snapshotKey = "stickyReachabilityMode"
    private static let maxAge: TimeInterval = 3 * 60 * 60
    private static let atStationMeters = LocationGuidancePolicy.stationRadiusMeters
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
        defaultsToWalking: Bool = false,
        walkingEstimate: SharedTravelTimeEstimateCache.Estimate? = nil,
        now: Date = Date()
    ) -> Mode? {
        guard distanceToStation > atStationMeters,
              distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        let validEstimate = walkingEstimate.flatMap {
            $0.originId == originId && (0..<300).contains(now.timeIntervalSince($0.fetchedAt)) ? $0 : nil
        }
        let routeDistance = validEstimate?.routeDistanceMeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let decisionDistance = routeDistance ?? distanceToStation
        if let snapshot = snapshot(now: now), snapshot.originId == originId {
            if snapshot.isManual == true {
                return snapshot.mode
            }
            // Correct a provisional choice once routing arrives, then retain the
            // established mode across countdown ticks and temporary routing loss.
            if routeDistance == nil || snapshot.usesWalkingRoute == true {
                if snapshot.mode == .driving {
                    return .driving
                }
                if decisionDistance < farEnoughToDriveMeters {
                    return .walking
                }
            }
        }

        let mode = inferredMode(
            distanceToStation: decisionDistance,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: defaultsToWalking,
            walkingMinutes: routeDistance == nil ? nil : validEstimate?.minutes
        )
        save(mode: mode, originId: originId, now: now, isManual: false, usesWalkingRoute: routeDistance != nil)
        return mode
    }

    static func save(
        mode: Mode,
        originId: Station.ID,
        now: Date = Date(),
        isManual: Bool = true,
        usesWalkingRoute: Bool = false
    ) {
        let snapshot = Snapshot(
            originId: originId,
            mode: mode,
            selectedAt: now,
            isManual: isManual,
            usesWalkingRoute: usesWalkingRoute
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        SharedWidgetReachabilityState.reconcileMode(originId: originId, mode: mode)
    }

    static func isManual(originId: Station.ID) -> Bool {
        guard let snapshot = snapshot(now: Date()), snapshot.originId == originId else { return false }
        return snapshot.isManual == true
    }

    static func useAutomatic(originId: Station.ID) {
        guard let snapshot = snapshot(now: Date()), snapshot.originId == originId else { return }
        defaults.removeObject(forKey: snapshotKey)
    }

    static func shouldRequestWalkingEstimate(distance: Double, originId: Station.ID) -> Bool {
        guard distance > atStationMeters, distance <= reachabilityMaxDistanceMeters else { return false }
        return distance <= farEnoughToDriveMeters
            || (snapshot(now: Date()).map { $0.originId == originId && $0.isManual == true && $0.mode == .walking } ?? false)
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
        minutesUntilDeparture: Int,
        defaultsToWalking: Bool,
        walkingMinutes: Int? = nil
    ) -> Mode {
        if distanceToStation <= closeEnoughToWalkMeters {
            return .walking
        }

        if distanceToStation >= farEnoughToDriveMeters {
            return .driving
        }

        if defaultsToWalking {
            return .walking
        }

        let minutes = walkingMinutes ?? max(1, Int(ceil((distanceToStation / 1.25) / 60)))
        return minutesUntilDeparture - minutes - 2 >= 0 ? .walking : .driving
    }
}

enum SharedCurrentLocationCache {
    struct Snapshot: Codable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let timestamp: Date
        var speed: CLLocationSpeed? = nil

        var location: CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: horizontalAccuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? -1,
                timestamp: timestamp
            )
        }
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let locationKey = "cachedCurrentLocation"
    private static let freshLocationRequiredUntilKey = "freshLocationRequiredUntil"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func save(_ location: CLLocation) {
        let snapshot = Snapshot(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            speed: location.speed.isFinite && location.speed >= 0 ? location.speed : nil
        )

        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: locationKey)
            defaults.removeObject(forKey: freshLocationRequiredUntilKey)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: locationKey)
    }

    static func requireFreshLocation(for duration: TimeInterval = 30) {
        defaults.set(Date().addingTimeInterval(duration), forKey: freshLocationRequiredUntilKey)
    }

    static var freshLocationRequired: Bool {
        guard let requiredUntil = defaults.object(forKey: freshLocationRequiredUntilKey) as? Date,
              requiredUntil > Date() else {
            defaults.removeObject(forKey: freshLocationRequiredUntilKey)
            return false
        }
        return true
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

struct TravelEstimateRequestGate {
    private var latest: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        latest = id
        return id
    }

    func accepts(_ id: UUID) -> Bool { latest == id }
}

enum EarlierDeparturesPolicy {
    static func visibleDepartures(_ departures: [Departure], isViewingToday: Bool, now: Date) -> [Departure] {
        departures.filter { shouldDisplay(departureDate: $0.departureDate, isViewingToday: isViewingToday, now: now) }
    }

    static func shouldDisplay(departureDate: Date, isViewingToday: Bool, now: Date) -> Bool {
        !isViewingToday || departureDate >= now
    }

    static func collapsibleCount(unreachable: [Bool?], hasReliableEstimate: Bool) -> Int {
        guard hasReliableEstimate else { return 0 }
        // Unknown guidance breaks the group; never collapse the entire list.
        let count = unreachable.prefix { $0 == true }.count
        return count < unreachable.count ? count : 0
    }
}

enum SharedTripState {
    struct Guidance: Codable {
        let location: SharedCurrentLocationCache.Snapshot
        let mode: SharedReachabilityModeStore.Mode?
        let travelMinutes: Int
        let estimateSource: String
        var estimateFetchedAt: Date? = nil

        var expirationDate: Date {
            if estimateSource == "At station" { return location.timestamp.addingTimeInterval(31) }
            let locationExpiry = location.timestamp.addingTimeInterval(181)
            guard estimateSource == "Maps estimate", let estimateFetchedAt else { return locationExpiry }
            return min(locationExpiry, estimateFetchedAt.addingTimeInterval(300))
        }

        static func meaningfullyChanged(from previous: Guidance?, to current: Guidance?, at now: Date) -> Bool {
            switch (previous, current) {
            case (nil, nil): return false
            case let (old?, new?):
                return old.mode != new.mode || old.travelMinutes != new.travelMinutes
                    || old.estimateSource != new.estimateSource
                    || (old.expirationDate <= now) != (new.expirationDate <= now)
            default: return true
            }
        }

        func hasFreshMapsEstimate(at date: Date) -> Bool {
            guard estimateSource == "Maps estimate", let estimateFetchedAt,
                  mode != nil, travelMinutes > 0,
                  LocationGuidancePolicy.isUsable(location.location, maxAge: 180, now: date) else { return false }
            return (0..<300).contains(date.timeIntervalSince(estimateFetchedAt))
        }
    }

    struct CatchResult {
        enum Status { case atStation, comfortable, tight, probablyMissed, tooLate }
        let status: Status
        let mode: SharedReachabilityModeStore.Mode?
        let travelMinutes: Int
        let arrivalAtStation: Date
        let leaveBy: Date

        var isMakeable: Bool {
            switch status {
            case .atStation, .comfortable, .tight: true
            case .probablyMissed, .tooLate: false
            }
        }
    }

    struct Snapshot: Codable {
        let schema: Int
        let routeRevision: Int
        let origin: Station
        let destination: Station
        let preparedAt: Date
        let departures: [Departure]
        let scheduleVersion: String?
        let scheduleExpired: Bool
        let scheduleExpiresAt: Date?
        let specialSchedules: [PATCOSpecialSchedule]
        let guidance: Guidance?
        let lastBroadcastAt: Date

        func isScheduleExpired(at date: Date) -> Bool {
            scheduleExpired || scheduleExpiresAt.map { date >= $0 } == true
        }

        func upcoming(at date: Date, limit: Int? = nil) -> [Departure] {
            let result = departures.filter { $0.departureDate >= date && !$0.isRemovedBySpecialSchedule }
            return limit.map { Array(result.prefix($0)) } ?? result
        }

        func catchResult(for departure: Departure, at date: Date, enforceOneHourLimit: Bool = true) -> CatchResult? {
            guard departure.origin.id == origin.id, departure.destination.id == destination.id,
                  departure.departureDate >= date,
                  !enforceOneHourLimit || departure.departureDate.timeIntervalSince(date) <= 3600,
                  !departure.isRemovedBySpecialSchedule, let guidance,
                  LocationGuidancePolicy.isUsable(guidance.location.location, maxAge: 180, now: date) else { return nil }
            let location = guidance.location.location
            if LocationGuidancePolicy.isAtStation(location, station: origin.location, now: date) {
                return .init(status: .atStation, mode: nil, travelMinutes: 0,
                             arrivalAtStation: date, leaveBy: departure.departureDate)
            }
            guard let mode = guidance.mode,
                  mode != .driving || guidance.hasFreshMapsEstimate(at: date),
                  guidance.estimateSource != "Maps estimate" || guidance.hasFreshMapsEstimate(at: date) else { return nil }
            let buffer = mode == .driving ? 3 : 2
            let spare = Int(floor(departure.departureDate.timeIntervalSince(date) / 60)) - guidance.travelMinutes - buffer
            let status: CatchResult.Status = spare >= 5 ? .comfortable : spare >= 0 ? .tight : spare < -5 ? .tooLate : .probablyMissed
            return .init(status: status, mode: mode, travelMinutes: guidance.travelMinutes,
                         arrivalAtStation: date.addingTimeInterval(Double(guidance.travelMinutes * 60)),
                         leaveBy: departure.departureDate.addingTimeInterval(-Double((guidance.travelMinutes + buffer) * 60)))
        }
    }

    struct Update {
        let snapshot: Snapshot
        let shouldReloadWidgets: Bool
    }

    // Uses the route coordinator's file lock so a result cannot commit across a route change.
    private static func locked<T>(directory: URL?, body: (URL, SharedRouteCoordinator.Route) -> T?) -> T? {
        guard let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.rhome.patconext") else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let descriptor = open(root.appendingPathComponent("route.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return nil }
            defer { flock(descriptor, LOCK_UN) }
            let route = try JSONDecoder().decode(SharedRouteCoordinator.Route.self,
                                                 from: Data(contentsOf: root.appendingPathComponent("resolved-route.json")))
            return body(root, route)
        } catch { return nil }
    }

    static func current(directory: URL? = nil) -> Snapshot? {
        locked(directory: directory) { root, route in
            guard let snapshot = read(root), snapshot.schema == 1, snapshot.routeRevision == route.revision,
                  snapshot.origin.id == route.originId, snapshot.destination.id == route.destinationId else { return nil }
            return snapshot
        }
    }

    private static func read(_ root: URL) -> Snapshot? {
        guard let snapshot = (try? Data(contentsOf: root.appendingPathComponent("trip-state.json"))).flatMap({
            try? JSONDecoder().decode(Snapshot.self, from: $0)
        }), snapshot.schema == 1 else { return nil }
        return snapshot
    }

    static func update(store: PATCOScheduleStore, routeRevision: Int, location: CLLocation?,
                       locationAllowed: Bool = true, now: Date = Date(), directory: URL? = nil,
                       specialSchedules: [PATCOSpecialSchedule] = []) -> Update? {
        // Compute schedules without holding the route lock needed by interactive actions.
        guard let preparedRoute = SharedRouteCoordinator.current(directory: directory),
              preparedRoute.revision == routeRevision else { return nil }
        let store = directory == nil ? PATCOScheduleStore() : store
        guard let origin = store.station(for: preparedRoute.originId),
              let destination = store.station(for: preparedRoute.destinationId), store.loadError == nil else { return nil }
        let specials = specialSchedules
        store.applySpecialSchedules(specials)
        let preparedDepartures = store.departures(from: origin, to: destination, after: now, limit: 500)
            .filter { !$0.isRemovedBySpecialSchedule }
        return locked(directory: directory) { root, route -> Update? in
            guard route.revision == routeRevision else { return nil }
            let previous = read(root)
            if let previous, previous.routeRevision == routeRevision, previous.preparedAt > now {
                return .init(snapshot: previous, shouldReloadWidgets: false)
            }
            var departures = preparedDepartures
            if previous?.routeRevision == routeRevision {
                // Preserve identity across refreshes for the same scheduled departure.
                let priorIDs = Dictionary(previous!.departures.map {
                    ("\($0.trip.id)|\($0.departureDate.timeIntervalSince1970)", $0.id)
                }, uniquingKeysWith: { first, _ in first })
                for index in departures.indices {
                    if let id = priorIDs["\(departures[index].trip.id)|\(departures[index].departureDate.timeIntervalSince1970)"] {
                        departures[index].id = id
                    }
                }
            }
            var best = locationAllowed ? location : nil
            if locationAllowed, let older = previous?.guidance?.location.location,
               LocationGuidancePolicy.isUsable(older, maxAge: 180, now: now),
               best.map({ !LocationGuidancePolicy.isUsable($0, maxAge: 180, now: now) || $0.timestamp < older.timestamp }) ?? true {
                best = older
            }
            var guidance: Guidance?
            if let best, LocationGuidancePolicy.isUsable(best, maxAge: 180, now: now) {
                let distance = best.distance(from: origin.location)
                if distance <= 150 * 1_609.34 {
                    let atStation = LocationGuidancePolicy.isAtStation(best, station: origin.location, now: now)
                    if atStation { SharedReachabilityModeStore.clearOnArrival(originId: origin.id) }
                    let mode = atStation ? nil : SharedReachabilityModeStore.resolve(
                        originId: origin.id, distanceToStation: distance,
                        minutesUntilDeparture: Int((departures.first?.departureDate ?? now).timeIntervalSince(now) / 60),
                        defaultsToWalking: origin.defaultsToWalkingForReachability,
                        walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: origin, currentLocation: best), now: now)
                    let estimate = mode.flatMap {
                        SharedTravelTimeEstimateCache.estimate(mode: $0 == .driving ? .driving : .walking,
                                                               origin: origin, currentLocation: best)
                    }
                    let minutes = atStation ? 0 : estimate?.minutes ?? (mode == .driving ? 0 : max(1, Int(ceil(distance / 75))))
                    guidance = .init(location: .init(latitude: best.coordinate.latitude, longitude: best.coordinate.longitude,
                                                     horizontalAccuracy: best.horizontalAccuracy, timestamp: best.timestamp),
                                     mode: mode, travelMinutes: minutes,
                                     estimateSource: atStation ? "At station" : estimate == nil ? (mode == .driving ? "Driving estimate unavailable" : "Distance-based fallback") : "Maps estimate",
                                     estimateFetchedAt: estimate?.fetchedAt)
                }
            }
            let routeChanged = previous?.routeRevision != routeRevision
            let scheduleChanged = previous?.scheduleVersion != store.scheduleFeedVersion
                || previous?.specialSchedules != specials
                || previous?.departures.first?.departureDate != departures.first?.departureDate
            // Coalesce cross-surface reloads; timeline generation must not create a reload loop.
            let guidanceChanged = Guidance.meaningfullyChanged(from: previous?.guidance, to: guidance, at: now)
            let broadcast = routeChanged || scheduleChanged || guidanceChanged || now.timeIntervalSince(previous?.lastBroadcastAt ?? .distantPast) >= 180
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
            let expiration = store.scheduleFeedEndDate.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            let snapshot = Snapshot(schema: 1, routeRevision: routeRevision, origin: origin, destination: destination,
                                    preparedAt: now, departures: departures, scheduleVersion: store.scheduleFeedVersion,
                                    scheduleExpired: store.feed?.isExpired(on: now) ?? true, scheduleExpiresAt: expiration,
                                    specialSchedules: specials,
                                    guidance: guidance, lastBroadcastAt: broadcast ? now : previous!.lastBroadcastAt)
            do {
                try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("trip-state.json"), options: .atomic)
                return .init(snapshot: snapshot, shouldReloadWidgets: broadcast)
            } catch { return nil }
        }
    }
}

enum SharedDiagnosticState {
    enum Surface: String, Codable, CaseIterable {
        case app = "App"
        case homeScreen = "Home Screen widget"
        case lockScreen = "Lock Screen widget"
    }

    struct Snapshot: Codable {
        let routeTitle: String
        let revision: Int?
        let recordedAt: Date
        let nextRequestedAt: Date?
        let locationTimestamp: Date?
        let accuracyMeters: Double?
        let travelEstimateSource: String?
        let appliedSpecialSchedules: [String]?
    }

    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard }

    static func snapshot(for surface: Surface, defaults storage: UserDefaults? = nil) -> Snapshot? {
        guard let data = (storage ?? defaults).data(forKey: key(surface)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func record(_ surface: Surface, origin: Station?, destination: Station?, revision: Int?,
                       at date: Date = Date(), nextRequestedAt: Date? = nil,
                       location: CLLocation? = nil, travelEstimateSource: String? = nil,
                       appliedSpecialSchedules: [String] = [],
                       defaults storage: UserDefaults? = nil) {
        let title = "\(origin?.name ?? "Unknown") to \(destination?.name ?? "Unknown")"
        if surface == .app, let previous = snapshot(for: surface, defaults: storage),
           previous.routeTitle == title, previous.revision == revision,
           previous.appliedSpecialSchedules == appliedSpecialSchedules,
           date.timeIntervalSince(previous.recordedAt) < 30 { return }
        let snapshot = Snapshot(routeTitle: title, revision: revision, recordedAt: date,
                                nextRequestedAt: nextRequestedAt, locationTimestamp: location?.timestamp,
                                accuracyMeters: location?.horizontalAccuracy, travelEstimateSource: travelEstimateSource,
                                appliedSpecialSchedules: appliedSpecialSchedules)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        (storage ?? defaults).set(data, forKey: key(surface))
    }

    private static func key(_ surface: Surface) -> String { "diagnosticSnapshot.\(surface.rawValue)" }
}

enum ArrivalDiagnostics {
    private static let key = "arrivalDiagnosticEvents"
    private static let lock = NSLock()

    static var events: [SharedWidgetDiagnostics.Event] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    static func record(_ title: String, detail: String) {
        lock.lock()
        defer { lock.unlock() }
        var recent = load()
        recent.insert(.init(id: UUID(), date: Date(), title: title, detail: detail), at: 0)
        if let data = try? JSONEncoder().encode(Array(recent.prefix(500))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func load() -> [SharedWidgetDiagnostics.Event] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SharedWidgetDiagnostics.Event].self, from: data)) ?? []
    }
}

enum SharedWidgetDiagnostics {
    struct ReloadRequest: Codable {
        let id: UUID
        let date: Date
        let action: String
        let revision: Int
        let originId: String
        let destinationId: String

        func outcome(revision loadedRevision: Int?, originId loadedOrigin: String?, destinationId loadedDestination: String?) -> String {
            guard let loadedRevision else { return "No matching committed route revision" }
            if loadedRevision > revision { return "Requested revision superseded by a newer route" }
            if loadedRevision == revision && loadedOrigin == originId && loadedDestination == destinationId {
                return "Requested route loaded"
            }
            return "Route mismatch with reload request"
        }
    }

    private static let reloadRequestKey = "widgetDiagnosticReloadRequest"

    static var latestReloadRequest: ReloadRequest? {
        guard let data = defaults.data(forKey: reloadRequestKey) else { return nil }
        return try? JSONDecoder().decode(ReloadRequest.self, from: data)
    }

    static func recordReloadRequest(action: String, deliveryDescription: String = "both widget kinds") {
        guard let route = SharedRouteCoordinator.current() else {
            record("Widget reload requested", detail: "\(action); no committed route; \(deliveryDescription)")
            return
        }
        let request = ReloadRequest(id: UUID(), date: Date(), action: action, revision: route.revision,
                                    originId: route.originId, destinationId: route.destinationId)
        if let data = try? JSONEncoder().encode(request) {
            defaults.set(data, forKey: reloadRequestKey)
        }
        record("Widget reload requested", detail: "Request \(request.id); \(action); expected revision \(route.revision): \(route.originId) to \(route.destinationId); \(deliveryDescription); iOS delivery not confirmed")
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        var title: String
        var detail: String
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let eventsKey = "widgetDiagnosticEvents"
    private static let limit = 100

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var events: [Event] {
        guard let data = defaults.data(forKey: eventsKey) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    static func record(_ title: String, detail: String) {
        var recent = events
        recent.insert(Event(id: UUID(), date: Date(), title: title, detail: detail), at: 0)
        save(recent)
    }

    @discardableResult
    static func beginWidgetRun(manual: Bool = false) -> UUID {
        let id = UUID()
        var recent = events
        recent.insert(
            Event(
                id: id,
                date: Date(),
                title: manual ? "Manual location check started" : "Widget timeline started",
                detail: "In progress"
            ),
            at: 0
        )
        save(recent)
        return id
    }

    static func recordLocation(_ outcome: String, duration: TimeInterval, for id: UUID) {
        update(id) { event in
            let durationText = duration < 1 ? "<1 sec" : "\(Int(duration.rounded())) sec"
            event.detail = "\(outcome) in \(durationText)"
        }
    }

    static func finishWidgetRun(
        _ id: UUID,
        manual: Bool = false,
        departureCount: Int? = nil,
        nextReloadAt: Date? = nil,
        nextReloadReason: String? = nil
    ) {
        update(id) { event in
            let elapsed = Int(Date().timeIntervalSince(event.date).rounded())
            event.title = manual ? "Manual location check finished" : "Widget timeline prepared"
            var details = event.detail == "In progress" ? [] : [event.detail]
            if let departureCount {
                details.append("\(departureCount) upcoming departures")
            }
            details.append("Completed in \(elapsed) sec")
            if let nextReloadAt {
                details.append("Next requested \(nextReloadAt.formatted(date: .omitted, time: .shortened))")
            }
            if let nextReloadReason {
                details.append(nextReloadReason)
            }
            event.detail = details.joined(separator: " · ")
        }
    }

    private static func update(_ id: UUID, change: (inout Event) -> Void) {
        var recent = events
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        change(&recent[index])
        save(recent)
    }

    private static func save(_ recent: [Event]) {
        var appCount = 0
        var widgetCount = 0
        let retained = recent.filter { event in
            if event.title.hasPrefix("App ") {
                appCount += 1
                return appCount <= limit
            }
            widgetCount += 1
            return widgetCount <= limit
        }
        if let data = try? JSONEncoder().encode(retained) {
            defaults.set(data, forKey: eventsKey)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: eventsKey)
        defaults.removeObject(forKey: reloadRequestKey)
    }
}
