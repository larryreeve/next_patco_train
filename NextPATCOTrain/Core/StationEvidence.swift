import Combine
import CoreLocation
import Foundation
import Darwin

struct StationStopEvidence: Codable, Equatable {
    private var stationId: String?
    private var firstAt: Date?
    private var lastAt: Date?
    private var latitude: Double?
    private var longitude: Double?
    private var missingSpeedWindow: Bool?
    private var sampleCount: Int?

    static func isReliableStop(_ location: CLLocation, now: Date) -> Bool {
        LocationGuidancePolicy.isUsable(location, maxAge: LocationThresholds.Station.maximumAge, now: now)
            && location.horizontalAccuracy <= LocationThresholds.Station.maximumAccuracy
            && location.speed.isFinite && location.speed >= 0 && location.speed <= LocationThresholds.Stop.maximumSpeed
    }

    static func isPresenceReading(_ location: CLLocation, now: Date) -> Bool {
        isReliableStop(location, now: now)
            || (LocationGuidancePolicy.isUsable(location, maxAge: LocationThresholds.Station.maximumAge, now: now)
                && location.horizontalAccuracy <= LocationThresholds.Stop.missingSpeedAccuracy && location.speed == -1)
    }

    func diagnosticDescription(for location: CLLocation, now: Date = Date(), preciseArrival: Bool = false, positionPresence: Bool = false) -> String {
        guard LocationGuidancePolicy.isUsable(location, maxAge: LocationThresholds.Station.maximumAge, now: now) else {
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
        return "Stopped evidence \(seconds) of \(Int(preciseArrival ? LocationThresholds.Stop.preciseDuration : LocationThresholds.Stop.standardDuration)) sec; \(sampleCount ?? 0) unique fixes; gaps over 15 sec restart confirmation"
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
              !preciseArrival || (Self.isReliableStop(location, now: now) && location.horizontalAccuracy <= LocationThresholds.Stop.preciseAccuracy),
              CLLocationCoordinate2DIsValid(station.coordinate),
              location.distance(from: station) + location.horizontalAccuracy <= LocationGuidancePolicy.stationRadiusMeters,
              nearestOtherDistance - location.distance(from: station) >= max(75, 2 * location.horizontalAccuracy) else {
            self = Self()
            return false
        }
        let anchor = latitude.flatMap { lat in longitude.map { CLLocation(latitude: lat, longitude: $0) } }
        if self.stationId != stationId || firstAt == nil || (missingSpeedWindow ?? false) != missingSpeed
            || lastAt.map({ location.timestamp.timeIntervalSince($0) > LocationThresholds.Stop.maximumGap }) == true
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
            location.timestamp.timeIntervalSince($0) >= (preciseArrival ? LocationThresholds.Stop.preciseDuration : LocationThresholds.Stop.standardDuration)
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
              location.horizontalAccuracy <= LocationThresholds.Underground.departureEvidenceMaximumAccuracy else {
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
        LocationGuidancePolicy.isUsable(location, maxAge: LocationThresholds.Station.maximumAge, now: now)
            && location.horizontalAccuracy <= LocationThresholds.Station.positionOnlyAccuracy
            && (location.speed == -1 || (location.speed.isFinite && location.speed >= 0 && location.speed <= LocationThresholds.Stop.maximumSpeed))
    }

    static func isPresenceReading(_ location: CLLocation, now: Date) -> Bool {
        LocationGuidancePolicy.isUsable(location, maxAge: LocationThresholds.Station.maximumAge, now: now)
            && location.horizontalAccuracy <= LocationThresholds.Station.maximumAccuracy
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
