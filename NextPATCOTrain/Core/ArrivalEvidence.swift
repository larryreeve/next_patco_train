import Combine
import CoreLocation
import Foundation
import Darwin

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
           location.horizontalAccuracy <= LocationThresholds.Station.maximumAccuracy,
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
           location.horizontalAccuracy.isFinite, LocationThresholds.Underground.arrivalAccuracyRange.contains(location.horizontalAccuracy),
           distance <= UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy),
           nearestOtherStationDistance - distance >= LocationThresholds.Underground.minimumStationSeparation,
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
        else if !location.horizontalAccuracy.isFinite || !LocationThresholds.Underground.arrivalAccuracyRange.contains(location.horizontalAccuracy) { undergroundReason = "accuracy outside underground range 50...2000 m" }
        else if distance > UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy) { undergroundReason = "outside destination proximity radius" }
        else if nearestOtherStationDistance - distance < LocationThresholds.Underground.minimumStationSeparation { undergroundReason = "ambiguous neighboring station" }
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
