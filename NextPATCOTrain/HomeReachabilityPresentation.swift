import CoreLocation
import Foundation

/// A value snapshot: recomputing guidance never owns a GPS or network request.
struct HomeReachabilityPresentation {
    let isViewingToday: Bool
    let departures: [Departure]
    let sharedTrip: SharedTripState.Snapshot?
    let authorizationStatus: CLAuthorizationStatus
    let reachabilityLocation: CLLocation?
    let isUsingTemporaryStationRoute: Bool
    let drivingEstimateInFlight: Bool
    let driveTimeEstimate: TravelTimeEstimate?
    let walkingTimeEstimate: TravelTimeEstimate?

    var isAtDepartureStation: Bool {
        isAtDepartureStation(at: Date())
    }

    func isAtDepartureStation(at now: Date) -> Bool {
        guard let origin = visibleDepartures(at: now).first?.origin,
              let location = usableReachabilityLocation(at: now) else {
            return false
        }
        return LocationGuidancePolicy.isAtStation(location, station: origin.location, now: now)
    }

    var usableReachabilityLocation: CLLocation? {
        usableReachabilityLocation(at: Date())
    }

    func usableReachabilityLocation(at now: Date) -> CLLocation? {
        guard LocationInteractionPolicy.isAuthorized(authorizationStatus),
              let location = sharedTrip?.guidance?.location.location ?? (sharedTrip == nil ? reachabilityLocation : nil),
              LocationGuidancePolicy.isUsable(location, maxAge: 180, now: now) else { return nil }
        return location
    }

    var reachabilityGuidance: (title: String, detail: String?, systemImage: String)? {
        reachabilityGuidance(at: Date())
    }

    func visibleDepartures(at now: Date) -> [Departure] {
        EarlierDeparturesPolicy.visibleDepartures(departures, isViewingToday: isViewingToday, now: now)
    }

    func reachabilityGuidance(at now: Date) -> (title: String, detail: String?, systemImage: String)? {
        guard isViewingToday,
              let departure = visibleDepartures(at: now).first else {
            return nil
        }
        let origin = departure.origin

        // This explains the displayed route, not the latest GPS fix. Keep it
        // until the temporary route is restored, including underground gaps.
        if isUsingTemporaryStationRoute {
            return ("Showing departures from \(origin.name) to \(departure.destination.name) based on your location.", nil, "tram.fill")
        }
        if isAtDepartureStation(at: now) { return nil }

        if currentReachabilityMode(at: now) == .driving {
            let hasEstimate = sharedTrip?.guidance?.hasFreshMapsEstimate(at: now)
                ?? usableReachabilityLocation(at: now).map {
                    SharedTravelTimeEstimateCache.estimate(mode: .driving, origin: origin, currentLocation: $0) != nil
                } ?? false
            if !hasEstimate {
                return (drivingEstimateInFlight ? "Calculating driving time…" : "Driving estimate unavailable", nil, "car.fill")
            }
        }

        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: true, at: now) else {
            return nil
        }
        let compactOriginName = origin.name.replacingOccurrences(of: " and ", with: " & ")
        guard let arrivalSummary = status.stationArrivalSummary(at: compactOriginName) else {
            return nil
        }
        let systemImage = arrivalSummary.mode == .driving ? "car.fill" : "figure.walk"
        let cachedRoute = usableReachabilityLocation(at: now).flatMap {
            SharedTravelTimeEstimateCache.estimate(mode: arrivalSummary.mode == .walking ? .walking : .driving,
                                                   origin: origin, currentLocation: $0)
        } != nil
        let hasRoute = sharedTrip?.guidance.map { $0.hasFreshMapsEstimate(at: now) } ?? cachedRoute
        let detail = "\(arrivalSummary.arrivalTime) if you leave now"
            + (hasRoute ? "" : " (straight-line estimate)")
        return ("Arrive at \(compactOriginName)", detail, systemImage)
    }

    var currentReachabilityMode: StationTravelMode? {
        currentReachabilityMode(at: Date())
    }

    func currentReachabilityMode(at now: Date) -> StationTravelMode? {
        let departures = visibleDepartures(at: now)
        if isViewingToday, let sharedTrip {
            guard !isAtDepartureStation(at: now), usableReachabilityLocation(at: now) != nil,
                  let mode = sharedTrip.guidance?.mode else { return nil }
            return StationTravelMode(mode)
        }
        guard isViewingToday,
              let currentLocation = usableReachabilityLocation(at: now),
              let firstDeparture = departures.first else {
            return nil
        }

        guard !isAtDepartureStation(at: now) else { return nil }

        let distanceToStation = currentLocation.distance(from: firstDeparture.origin.location)
        guard distanceToStation <= StationTravelMode.reachabilityMaxDistanceMeters else {
            return nil
        }

        guard distanceToStation > StationTravelMode.atStationMeters else {
            return nil
        }

        let minutesUntilDeparture = Int(floor(firstDeparture.departureDate.timeIntervalSince(now) / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: firstDeparture.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: firstDeparture.origin.defaultsToWalkingForReachability,
            walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: firstDeparture.origin, currentLocation: currentLocation), now: now
        ) else {
            return nil
        }

        return StationTravelMode(sharedMode)
    }

    var reachabilityUnavailableMessage: String? {
        guard isViewingToday, usableReachabilityLocation == nil else { return nil }

        switch authorizationStatus {
        case .notDetermined, .denied, .restricted:
            return "Location unavailable. Enable Location Services to see which train you can make."
        default:
            return "Tap Refresh to see trains you can catch."
        }
    }

    var reachabilityLocationActionTitle: String {
        switch authorizationStatus {
        case .denied, .restricted:
            return "Open Settings"
        case .notDetermined:
            return "Enable Location"
        default:
            return "Refresh Location"
        }
    }

    func hasReliableDepartureEstimate(at now: Date) -> Bool {
        guard isViewingToday, !isAtDepartureStation(at: now),
              let origin = visibleDepartures(at: now).first?.origin,
              let location = usableReachabilityLocation(at: now) else { return false }
        if let sharedTrip {
            return sharedTrip.guidance?.hasFreshMapsEstimate(at: now) == true
        }
        guard let mode = currentReachabilityMode(at: now) else { return false }
        let estimate = mode == .driving ? driveTimeEstimate : walkingTimeEstimate
        return estimate?.isValid(for: origin, currentLocation: location, now: now) == true
    }

    func catchStatus(for departure: Departure, at date: Date = Date()) -> TrainCatchStatus? {
        guard !departure.isRemovedBySpecialSchedule else { return nil }
        guard isViewingToday else { return nil }
        return reachabilityStatus(for: departure, enforceOneHourLimit: false, at: date)
    }

    func listCatchStatus(for departure: Departure, at date: Date) -> TrainCatchStatus? {
        guard !departure.isRemovedBySpecialSchedule else { return nil }
        guard isViewingToday else { return nil }
        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: true, at: date) else {
            return nil
        }

        if case .atStation = status {
            return nil
        }

        return status
    }

    func reachabilityStatus(for departure: Departure, enforceOneHourLimit: Bool, at now: Date = Date()) -> TrainCatchStatus? {
        guard LocationInteractionPolicy.isAuthorized(authorizationStatus) else { return nil }
        if let sharedTrip {
            guard !enforceOneHourLimit || departure.departureDate.timeIntervalSince(now) <= 3600,
                  let result = sharedTrip.catchResult(for: departure, at: now, enforceOneHourLimit: enforceOneHourLimit) else { return nil }
            if result.status == .atStation { return .atStation }
            guard let mode = result.mode else { return nil }
            let travelMode = StationTravelMode(mode)
            switch result.status {
            case .atStation: return .atStation
            case .comfortable: return .comfortable(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            case .tight: return .tight(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            case .probablyMissed: return .probablyMissed(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            case .tooLate: return .tooLate(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            }
        }
        guard let currentLocation = usableReachabilityLocation(at: now) else {
            return nil
        }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        guard distanceToStation <= StationTravelMode.reachabilityMaxDistanceMeters else {
            return nil
        }

        guard !enforceOneHourLimit || minutesUntilDeparture <= 60 else {
            return nil
        }
        if LocationGuidancePolicy.isAtStation(currentLocation, station: departure.origin.location, now: now) {
            return .atStation
        }

        let travelMode = currentReachabilityMode(at: now) ?? StationTravelMode.inferred(
            forMeters: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        )
        let stationBufferMinutes = travelMode.stationBufferMinutes
        guard let travelMinutes = travelMinutes(
            for: travelMode,
            distanceToStation: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        ) else { return nil }
        let spareMinutes = minutesUntilDeparture - travelMinutes - stationBufferMinutes
        let arrivalAtStationDate = now.addingTimeInterval(TimeInterval(travelMinutes * 60))
        let leaveByDate = departure.departureDate.addingTimeInterval(-TimeInterval((travelMinutes + stationBufferMinutes) * 60))

        if spareMinutes >= 5 {
            return .comfortable(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
        }
        if spareMinutes >= 0 {
            return .tight(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
        }
        if spareMinutes < -5 {
            return .tooLate(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
        }
        return .probablyMissed(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
    }

    func travelMinutes(
        for mode: StationTravelMode,
        distanceToStation: CLLocationDistance,
        origin: Station,
        currentLocation: CLLocation
    ) -> Int? {
        if mode == .walking,
           let walkingTimeEstimate,
           walkingTimeEstimate.isValid(for: origin, currentLocation: currentLocation) {
            return walkingTimeEstimate.minutes
        }

        guard mode == .driving,
              let driveTimeEstimate,
              driveTimeEstimate.isValid(for: origin, currentLocation: currentLocation) else {
            if mode == .driving {
                return SharedTravelTimeEstimateCache.estimate(mode: .driving, origin: origin, currentLocation: currentLocation)?.minutes
            }
            return mode.travelMinutes(forMeters: distanceToStation)
        }

        return driveTimeEstimate.minutes
    }

}
