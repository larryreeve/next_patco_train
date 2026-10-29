import Observation
import CoreLocation
import MapKit

/// Owns asynchronous estimates; the context is read again after awaiting to reject obsolete results.
@MainActor @Observable
final class TravelEstimateController {
    struct RouteEstimate {
        let expectedTravelTime: TimeInterval
        let distance: CLLocationDistance
    }

    struct Cache {
        var defaults: UserDefaults? = nil
        var directory: URL? = nil

        func estimate(mode: SharedTravelTimeEstimateCache.Mode, origin: Station,
                      currentLocation: CLLocation, now: Date) -> SharedTravelTimeEstimateCache.Estimate? {
            SharedTravelTimeEstimateCache.estimate(mode: mode, origin: origin,
                currentLocation: currentLocation, now: now, defaults: defaults)
        }

        func save(mode: SharedTravelTimeEstimateCache.Mode, origin: Station, currentLocation: CLLocation,
                  minutes: Int, fetchedAt: Date, routeDistanceMeters: Double? = nil, requestStartedAt: Date) {
            SharedTravelTimeEstimateCache.save(mode: mode, origin: origin, currentLocation: currentLocation,
                minutes: minutes, fetchedAt: fetchedAt, routeDistanceMeters: routeDistanceMeters,
                requestStartedAt: requestStartedAt, defaults: defaults, directory: directory)
        }

        func clear(mode: SharedTravelTimeEstimateCache.Mode, ifNotNewerThan: Date? = nil, originId: Station.ID? = nil) {
            SharedTravelTimeEstimateCache.clear(mode: mode, ifNotNewerThan: ifNotNewerThan,
                originId: originId, defaults: defaults, directory: directory)
        }
    }

    struct Context {
        var isActive: Bool
        var isViewingToday: Bool
        var originId: Station.ID?
        var routeRevision: Int?
        var location: CLLocation?
        var authorization: CLAuthorizationStatus
    }

    var driveTimeEstimate: TravelTimeEstimate?
    var walkingTimeEstimate: TravelTimeEstimate?
    private(set) var walkingEstimateInFlight = false
    private(set) var drivingEstimateInFlight = false
    @ObservationIgnored private var walkingEstimateRequests = TravelEstimateRequestGate()
    @ObservationIgnored private var drivingEstimateRequests = TravelEstimateRequestGate()
    private let now: () -> Date
    private let calculate: (MKDirections.Request) async throws -> RouteEstimate?
    private let cache: Cache

    init(now: @escaping () -> Date = Date.init, cache: Cache = Cache(),
         calculate: @escaping (MKDirections.Request) async throws -> RouteEstimate? = {
             let response = try await MKDirections(request: $0).calculate()
             return response.routes.first.map { RouteEstimate(expectedTravelTime: $0.expectedTravelTime, distance: $0.distance) }
         }) {
        self.now = now
        self.cache = cache
        self.calculate = calculate
    }

    @MainActor
    func refreshWalkingTimeEstimate(origin: Station, force: Bool, context: () -> Context) async {
        guard context().isActive, context().isViewingToday, context().originId == origin.id,
              !Task.isCancelled, !walkingEstimateInFlight else { return }
        walkingEstimateInFlight = true
        defer { walkingEstimateInFlight = false }
        let requestID = walkingEstimateRequests.begin()
        let requestStartedAt = now()
        let requestRevision = context().routeRevision
        guard let currentLocation = context().location else {
            walkingTimeEstimate = nil
            cache.clear(mode: .walking)
            return
        }

        let distanceToStation = currentLocation.distance(from: origin.location)
        guard SharedReachabilityModeStore.shouldRequestWalkingEstimate(distance: distanceToStation, originId: origin.id) else {
            walkingTimeEstimate = nil
            cache.clear(mode: .walking)
            return
        }

        if !force, let walkingTimeEstimate, walkingTimeEstimate.isValid(for: origin, currentLocation: currentLocation, now: now()) {
            return
        }

        if !force, let cached = cache.estimate(mode: .walking, origin: origin, currentLocation: currentLocation, now: now()),
           cached.routeDistanceMeters != nil {
            walkingTimeEstimate = TravelTimeEstimate(originId: origin.id,
                sourceLocation: CLLocation(latitude: cached.sourceLatitude, longitude: cached.sourceLongitude),
                minutes: cached.minutes, fetchedAt: cached.fetchedAt, routeDistanceMeters: cached.routeDistanceMeters)
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await calculate(request)
            guard walkingEstimateRequests.accepts(requestID), context().routeRevision == requestRevision,
                  let latestLocation = context().location,
                  latestLocation.distance(from: currentLocation) < 50 else { return }
            guard context().isViewingToday, context().originId == origin.id, !Task.isCancelled else { return }
            guard LocationInteractionPolicy.isAuthorized(context().authorization) else { return }
            guard let route = response else { return }

            let estimate = TravelTimeEstimate(
                originId: origin.id,
                sourceLocation: currentLocation,
                minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                fetchedAt: now(),
                routeDistanceMeters: route.distance
            )
            walkingTimeEstimate = estimate
            cache.save(
                mode: .walking,
                origin: origin,
                currentLocation: currentLocation,
                minutes: estimate.minutes,
                fetchedAt: estimate.fetchedAt,
                routeDistanceMeters: estimate.routeDistanceMeters,
                requestStartedAt: requestStartedAt
            )
        } catch {
            guard walkingEstimateRequests.accepts(requestID), context().routeRevision == requestRevision else { return }
            guard context().isViewingToday, context().originId == origin.id, !Task.isCancelled else { return }
            walkingTimeEstimate = nil
            cache.clear(mode: .walking, ifNotNewerThan: requestStartedAt, originId: origin.id)
        }
    }

    @MainActor
    func refreshDriveTimeEstimate(origin: Station, force: Bool, context: () -> Context) async {
        guard context().isActive, context().isViewingToday, context().originId == origin.id,
              !Task.isCancelled, !drivingEstimateInFlight else { return }
        drivingEstimateInFlight = true
        defer { drivingEstimateInFlight = false }
        let requestID = drivingEstimateRequests.begin()
        let requestStartedAt = now()
        let requestRevision = context().routeRevision
        guard let currentLocation = context().location else {
            driveTimeEstimate = nil
            cache.clear(mode: .driving)
            return
        }

        let distanceToStation = currentLocation.distance(from: origin.location)
        guard distanceToStation > StationTravelMode.atStationMeters else {
            driveTimeEstimate = nil
            cache.clear(mode: .driving)
            return
        }

        if !force, let driveTimeEstimate, driveTimeEstimate.isValid(for: origin, currentLocation: currentLocation, now: now()) {
            return
        }

        if !force, let cached = cache.estimate(mode: .driving, origin: origin, currentLocation: currentLocation, now: now()) {
            driveTimeEstimate = TravelTimeEstimate(originId: origin.id,
                sourceLocation: CLLocation(latitude: cached.sourceLatitude, longitude: cached.sourceLongitude),
                minutes: cached.minutes, fetchedAt: cached.fetchedAt, routeDistanceMeters: cached.routeDistanceMeters)
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        do {
            let response = try await calculate(request)
            guard drivingEstimateRequests.accepts(requestID), context().routeRevision == requestRevision,
                  let latestLocation = context().location,
                  latestLocation.distance(from: currentLocation) < 50 else { return }
            guard context().isViewingToday, context().originId == origin.id, !Task.isCancelled else { return }
            guard LocationInteractionPolicy.isAuthorized(context().authorization) else { return }
            guard let route = response else { return }

            let routeMinutes = max(1, Int(ceil(route.expectedTravelTime / 60)))
            let estimate = TravelTimeEstimate(
                originId: origin.id,
                sourceLocation: currentLocation,
                minutes: routeMinutes,
                fetchedAt: now()
            )
            driveTimeEstimate = estimate
            cache.save(
                mode: .driving,
                origin: origin,
                currentLocation: currentLocation,
                minutes: estimate.minutes,
                fetchedAt: estimate.fetchedAt,
                requestStartedAt: requestStartedAt
            )
        } catch {
            guard drivingEstimateRequests.accepts(requestID), context().routeRevision == requestRevision else { return }
            guard context().isViewingToday, context().originId == origin.id, !Task.isCancelled else { return }
            driveTimeEstimate = nil
            cache.clear(mode: .driving, ifNotNewerThan: requestStartedAt, originId: origin.id)
        }
    }

}
