import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

enum WidgetCatchStatus: Equatable {
    case reachable
    case tight
    case likelyMiss

    private static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    init?(
        departure: Departure,
        currentLocation: CLLocation?,
        now: Date,
        reachabilityMode: TravelMode?
    ) {
        guard let currentLocation, LocationGuidancePolicy.isUsable(currentLocation, maxAge: 180, now: now) else { return nil }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= Self.reachabilityMaxDistanceMeters else {
            return nil
        }

        if LocationGuidancePolicy.isAtStation(currentLocation, station: departure.origin.location, now: now) {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            self = .reachable
            return
        }

        guard let travelMode = reachabilityMode ?? SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: departure.origin.defaultsToWalkingForReachability,
            walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: departure.origin, currentLocation: currentLocation)
        ).map(TravelMode.init) else {
            return nil
        }
        guard let travelMinutes = Self.travelMinutes(
            for: travelMode,
            meters: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        ) else { return nil }
        let stationAccessMinutes = travelMode == .driving ? 3 : 2
        let spareMinutes = minutesUntilDeparture - travelMinutes - stationAccessMinutes

        if spareMinutes >= 5 {
            self = .reachable
        } else if spareMinutes >= 0 {
            self = .tight
        } else {
            self = .likelyMiss
        }
    }

    var color: Color {
        switch self {
        case .reachable:
            Color(red: 0.43, green: 0.86, blue: 0.55)
        case .tight:
            Color.patcoGold
        case .likelyMiss:
            Color(red: 1.0, green: 0.50, blue: 0.56)
        }
    }

    var isMakeable: Bool {
        switch self {
        case .reachable, .tight:
            true
        case .likelyMiss:
            false
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .reachable: "Likely to make this train"
        case .tight: "Timing is tight"
        case .likelyMiss: "Likely to miss this train"
        }
    }

    init(_ result: SharedTripState.CatchResult) {
        switch result.status {
        case .atStation, .comfortable: self = .reachable
        case .tight: self = .tight
        case .probablyMissed, .tooLate: self = .likelyMiss
        }
    }

    enum TravelMode {
        case walking
        case driving

        init(_ sharedMode: SharedReachabilityModeStore.Mode) {
            self = sharedMode == .driving ? .driving : .walking
        }

        var sharedMode: SharedReachabilityModeStore.Mode {
            self == .driving ? .driving : .walking
        }
    }

    static func reachabilityMode(
        for departure: Departure?,
        currentLocation: CLLocation?,
        now: Date
    ) -> TravelMode? {
        guard let departure, let currentLocation,
              LocationGuidancePolicy.isUsable(currentLocation, maxAge: 180, now: now) else { return nil }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        guard !LocationGuidancePolicy.isAtStation(currentLocation, station: departure.origin.location, now: now) else {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            return nil
        }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: departure.origin.defaultsToWalkingForReachability,
            walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: departure.origin, currentLocation: currentLocation)
        ) else {
            return nil
        }

        return TravelMode(sharedMode)
    }

    private static func travelMinutes(
        for mode: TravelMode,
        meters: CLLocationDistance,
        origin: Station,
        currentLocation: CLLocation
    ) -> Int? {
        let cacheMode: SharedTravelTimeEstimateCache.Mode = mode == .walking ? .walking : .driving
        if let estimate = SharedTravelTimeEstimateCache.estimate(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation
        ) {
            return estimate.minutes
        }

        guard mode != .driving else { return nil }
        return travelMinutes(for: mode, meters: meters)
    }

    private static func travelMinutes(for mode: TravelMode, meters: CLLocationDistance) -> Int {
        switch mode {
        case .walking:
            return max(1, Int(ceil((meters / 1.25) / 60)))
        case .driving:
            let metersPerMinuteAt25MPH = 670.56
            return max(1, Int(ceil(meters / metersPerMinuteAt25MPH)))
        }
    }
}
