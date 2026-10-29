import Combine
import CoreLocation
import Foundation
import Darwin

/// Separate budgets are intentional: guidance may use a coarser fix than station evidence.
enum LocationThresholds {
    enum Guidance {
        static let maximumAccuracy = 150.0
        static let defaultAge: TimeInterval = 120
        static let stationSelectionAge: TimeInterval = 30
        static let minimumStationSeparation = 75.0
    }
    enum Station {
        static let radius = 150.0
        static let maximumAge: TimeInterval = 15
        static let maximumAccuracy = 50.0
        static let positionOnlyAccuracy = 30.0
    }
    enum Stop {
        static let maximumSpeed = 0.5
        static let missingSpeedAccuracy = 10.0
        static let preciseAccuracy = 20.0
        static let maximumGap: TimeInterval = 15
        static let preciseDuration: TimeInterval = 5
        static let standardDuration: TimeInterval = 10
    }
    enum Underground {
        static let departureEvidenceMaximumAccuracy = 3000.0
        static let arrivalAccuracyRange = 50.0...2000.0
        static let minimumStationSeparation = 150.0
        static let intermediateMaximumGap: TimeInterval = 45
        // Repeated coarse readings are estimates, not precise GPS confirmation.
        static let intermediateDuration: TimeInterval = 5
        static let destinationDuration: TimeInterval = 10
        static let destinationMaximumGap: TimeInterval = 90
        static let minimumReadings = 2
        static let minimumRadius = 100.0
        static let maximumRadius = 150.0
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
    static let stationRadiusMeters = LocationThresholds.Station.radius

    static func nearestUnambiguousStation(_ location: CLLocation, stations: [Station], now: Date = Date()) -> Station? {
        guard isUsable(location, maxAge: LocationThresholds.Guidance.stationSelectionAge, now: now),
              CLLocationCoordinate2DIsValid(location.coordinate),
              let nearest = stations.min(by: { location.distance(from: $0.location) < location.distance(from: $1.location) }) else { return nil }
        let distance = location.distance(from: nearest.location)
        guard stations.filter({ $0.id != nearest.id }).allSatisfy({
            location.distance(from: $0.location) - distance >= max(LocationThresholds.Guidance.minimumStationSeparation, 2 * location.horizontalAccuracy)
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

    static func isUsable(_ location: CLLocation, maxAge: TimeInterval = LocationThresholds.Guidance.defaultAge, now: Date = Date()) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && (0...maxAge).contains(now.timeIntervalSince(location.timestamp))
            && location.horizontalAccuracy > 0 && location.horizontalAccuracy <= LocationThresholds.Guidance.maximumAccuracy
    }

    static func isAtStation(_ location: CLLocation, station: CLLocation, now: Date = Date()) -> Bool {
        isUsable(location, maxAge: LocationThresholds.Guidance.stationSelectionAge, now: now)
            && location.distance(from: station) + location.horizontalAccuracy <= stationRadiusMeters
    }

    static func hasLeftStation(_ location: CLLocation, station: CLLocation, now: Date = Date()) -> Bool {
        isUsable(location, maxAge: LocationThresholds.Guidance.stationSelectionAge, now: now)
            && location.distance(from: station) - location.horizontalAccuracy > stationRadiusMeters
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
              LocationGuidancePolicy.isUsable(location, maxAge: LocationThresholds.Guidance.stationSelectionAge, now: now),
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

enum UrbanStationArrivalPolicy {
    static let intermediateConfirmationSeconds = LocationThresholds.Underground.intermediateDuration
    static let destinationConfirmationSeconds = LocationThresholds.Underground.destinationDuration
    static let destinationMaximumReadingGap = LocationThresholds.Underground.destinationMaximumGap
    static let intermediateMinimumReadings = LocationThresholds.Underground.minimumReadings

    static func radius(accuracy: Double) -> Double {
        guard accuracy.isFinite, accuracy > 0 else { return LocationThresholds.Underground.minimumRadius }
        return min(LocationThresholds.Underground.maximumRadius, max(LocationThresholds.Underground.minimumRadius, accuracy * 1.5))
    }

    static func isNearScheduledArrival(_ arrival: Date, now: Date) -> Bool {
        (-180...600).contains(now.timeIntervalSince(arrival))
    }
}
