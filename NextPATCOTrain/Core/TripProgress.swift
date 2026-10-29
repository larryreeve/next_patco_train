import Combine
import CoreLocation
import Foundation
import Darwin

enum TripArrivalEstimatePolicy {
    static let gpsMaximumAge: TimeInterval = 15
    static let stationAnchorMaximumAge: TimeInterval = 120
    static let maximumTrackOffsetMeters = 150.0
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
              location.horizontalAccuracy > 0, location.horizontalAccuracy <= LocationThresholds.Station.maximumAccuracy,
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

enum TripMapFocus {
    static func stationIndices(stations: [Station], completedIds: Set<String>,
                               position: CLLocationCoordinate2D?) -> [Int] {
        guard !stations.isEmpty else { return [] }
        let passed = stations.lastIndex { completedIds.contains($0.id) } ?? 0
        let nearest = position.flatMap { coordinate -> Int? in
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return stations.indices.min { location.distance(from: stations[$0].location) < location.distance(from: stations[$1].location) }
        } ?? passed
        let anchor = max(passed, nearest)
        return Array(max(0, anchor - 1)...min(stations.count - 1, anchor + 1))
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
            if let projected = PATCOTrackGeometry.projection(of: location, onto: route), projected.offset <= TripArrivalEstimatePolicy.maximumTrackOffsetMeters {
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
              (0...TripArrivalEstimatePolicy.stationAnchorMaximumAge).contains(now.timeIntervalSince(observedAt)),
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
        let fresh = (0...TripArrivalEstimatePolicy.gpsMaximumAge).contains(now.timeIntervalSince(positionAt))
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
                  location.horizontalAccuracy.isFinite, LocationThresholds.Underground.arrivalAccuracyRange.contains(location.horizontalAccuracy) else { return }
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
                if urbanCandidateId != nearest.element.id || urbanReadingCount == nil || urbanLastAt.map({ location.timestamp.timeIntervalSince($0) > LocationThresholds.Underground.intermediateMaximumGap }) ?? true {
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
