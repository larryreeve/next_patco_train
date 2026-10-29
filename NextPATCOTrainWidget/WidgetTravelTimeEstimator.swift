import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

@MainActor
private final class BoundedWidgetDirections {
    struct RouteEstimate: Sendable {
        let expectedTravelTime: TimeInterval
        let distance: Double
    }
    private let directions: MKDirections
    private var continuation: CheckedContinuation<RouteEstimate?, Never>?
    private var timeout: Task<Void, Never>?

    private init(_ request: MKDirections.Request) {
        directions = MKDirections(request: request)
    }

    static func calculate(_ request: MKDirections.Request) async -> RouteEstimate? {
        let operation = BoundedWidgetDirections(request)
        return await withCheckedContinuation { continuation in
            operation.continuation = continuation
            operation.timeout = Task {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) }
                catch { return }
                operation.directions.cancel()
                operation.finish(nil)
            }
            operation.directions.calculate { response, _ in
                let travelTime = response?.routes.first.map {
                    RouteEstimate(expectedTravelTime: $0.expectedTravelTime, distance: $0.distance)
                }
                Task { @MainActor in operation.finish(travelTime) }
            }
        }
    }

    private func finish(_ response: RouteEstimate?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: response)
    }
}

enum WidgetTravelTimeEstimator {
    @MainActor private static var walkingRequests = TravelEstimateRequestGate()
    @MainActor private static var drivingRequests = TravelEstimateRequestGate()
    @MainActor private static var pendingEstimates: [String: Task<Bool, Never>] = [:]
    @MainActor
    static func refresh(
        mode: WidgetCatchStatus.TravelMode,
        origin: Station,
        currentLocation: CLLocation,
        force: Bool
    ) async -> Bool {
        let key = "\(origin.id)|\(mode)|\(SharedRouteCoordinator.current()?.revision ?? -1)|\(currentLocation.coordinate.latitude)|\(currentLocation.coordinate.longitude)|\(force)"
        if let pending = pendingEstimates[key] { return await pending.value }
        let task = Task { @MainActor in
            await performRefresh(mode: mode, origin: origin, currentLocation: currentLocation, force: force)
        }
        pendingEstimates[key] = task
        defer { pendingEstimates[key] = nil }
        return await task.value
    }

    @MainActor
    private static func performRefresh(mode: WidgetCatchStatus.TravelMode, origin: Station,
                                       currentLocation: CLLocation, force: Bool) async -> Bool {
        guard WidgetReachabilitySettings.isEnabled else { return false }
        let requestID = mode == .walking ? walkingRequests.begin() : drivingRequests.begin()
        let requestRevision = SharedRouteCoordinator.current()?.revision
        let requestStartedAt = Date()
        let distanceToStation = currentLocation.distance(from: origin.location)
        let cacheMode: SharedTravelTimeEstimateCache.Mode
        let transportType: MKDirectionsTransportType

        switch mode {
        case .walking:
            guard distanceToStation > 150 else {
                SharedTravelTimeEstimateCache.clear(mode: .walking)
                return false
            }
            cacheMode = .walking
            transportType = .walking
        case .driving:
            guard distanceToStation > 150 else {
                SharedTravelTimeEstimateCache.clear(mode: .driving)
                return false
            }
            cacheMode = .driving
            transportType = .automobile
        }

        // Reuse the route estimate, not its old location or catchability result.
        if !force, let estimate = SharedTravelTimeEstimateCache.estimate(
            mode: cacheMode, origin: origin, currentLocation: currentLocation
        ) {
            SharedWidgetDiagnostics.record("Widget travel estimate reused",
                detail: "\(cacheMode.rawValue); \(estimate.minutes) min; original estimate age \(Int(Date().timeIntervalSince(estimate.fetchedAt))) sec")
            return true
        }

        SharedWidgetDiagnostics.record("Widget Maps estimate requested",
            detail: "\(cacheMode.rawValue); \(force ? "interactive refresh" : "cache absent or invalid")")
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        guard let travelTime = await BoundedWidgetDirections.calculate(request) else {
            SharedWidgetDiagnostics.record("Widget Maps estimate unavailable", detail: "\(cacheMode.rawValue); request failed or timed out")
            return false
        }
        guard WidgetReachabilitySettings.isEnabled, !Task.isCancelled,
              (mode == .walking ? walkingRequests.accepts(requestID) : drivingRequests.accepts(requestID)),
              let route = SharedRouteCoordinator.current(), route.revision == requestRevision, route.originId == origin.id,
              let latestLocation = SharedCurrentLocationCache.location(),
              LocationGuidancePolicy.isUsable(latestLocation, maxAge: 180),
              latestLocation.distance(from: currentLocation) < (mode == .walking ? 50 : 100) else {
            SharedWidgetDiagnostics.record("Widget Maps estimate discarded",
                detail: "\(cacheMode.rawValue); request superseded, route/location changed, permission setting changed, or work cancelled")
            return false
        }

        let saved = SharedTravelTimeEstimateCache.save(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation,
            minutes: max(1, Int(ceil(travelTime.expectedTravelTime / 60))),
            routeDistanceMeters: travelTime.distance,
            requestStartedAt: requestStartedAt
        )
        SharedWidgetDiagnostics.record(saved ? "Widget Maps estimate saved" : "Widget Maps estimate not saved",
            detail: "\(cacheMode.rawValue); \(max(1, Int(ceil(travelTime.expectedTravelTime / 60)))) min; route revision \(requestRevision.map(String.init) ?? "none")")
        return saved
    }
}
