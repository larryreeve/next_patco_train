import Foundation
import CoreLocation

@main
struct AppLocationIntegrationCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        let env = LocationTestEnvironment()
        let provider = env.provider()
        var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: env.now.addingTimeInterval(-60), directory: directory)!
        func poll(_ request: inout NearestStationSelectionRequest, foreground: Bool = true,
                  today: Bool = true, cancelled: Bool = false) -> NearestStationSelectionRequest.Outcome {
            request.poll(location: provider.currentLocation, authorization: provider.authorizationStatus,
                isForeground: foreground, isViewingToday: today, cancelled: cancelled,
                stations: stations, now: env.now, directory: directory)
        }
        env.manager.send([env.fix(latitude: 39.95, secondsAgo: 20)])
        var request = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        provider.requestLocation()
        precondition(poll(&request) == .waiting)
        env.now += 3
        env.manager.send([env.fix(latitude: 39.95)])
        guard case .selected(let selected) = poll(&request) else { preconditionFailure("Fresh compass callback was not applied") }
        route = selected
        precondition(route.originId == "B" && route.destinationId == "A" && route.manual)
        precondition(poll(&request) == .selected(selected))
        precondition(SharedRouteCoordinator.current(directory: directory) == selected)
        env.now += 1
        env.manager.send([env.fix(latitude: 39.95, secondsAgo: 40)])
        var timeout = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        provider.requestLocation()
        env.manager.fail(.network)
        precondition(poll(&timeout) == .waiting)
        env.now += 8
        precondition(poll(&timeout) == .staleLocation)
        env.manager.send([env.fix()])
        precondition(poll(&timeout) == .staleLocation && SharedRouteCoordinator.current(directory: directory) == route)
        for reason in 0..<3 {
            var cancelledRequest = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
            precondition(poll(&cancelledRequest, foreground: reason != 0, today: reason != 1,
                              cancelled: reason == 2) == .cancelled)
            precondition(poll(&cancelledRequest) == .cancelled)
        }
        var permissionRequest = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        env.manager.authorize(.denied)
        precondition(poll(&permissionRequest) == .denied && provider.currentLocation == nil)
        precondition(SharedRouteCoordinator.current(directory: directory) == route)
        env.manager.authorize(.authorizedAlways)
        var racing = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        route = SharedRouteCoordinator.reverse(expectedRevision: route.revision, now: env.now, directory: directory)!
        env.now += 1
        env.manager.send([env.fix(latitude: 39.965)])
        precondition(poll(&racing) == .routeChanged)
        precondition(SharedRouteCoordinator.current(directory: directory) == route)
        // The return button and automatic departure restoration use the same persisted context.
        for explicitReturn in [true, false] {
            route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
                originId: "C", destinationId: "B", stations: stations, automatic: true,
                now: env.now, directory: directory)!
            route = SharedRouteCoordinator.current(directory: directory)!
            let context = route.temporaryRoute!
            provider.isInBackground = true
            var callbacks = 0
            provider.onLocationUpdate = { _ in callbacks += 1 }
            env.now += 1
            env.manager.send([env.fix(latitude: 39.96)])
            precondition(callbacks == 1)
            route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                departureLocation: explicitReturn ? nil : provider.currentLocation,
                requireDeparture: !explicitReturn, stations: stations, now: env.now, directory: directory)!
            precondition(route.originId == context.originId && route.destinationId == context.destinationId)
            precondition(route.manual == context.manual && route.temporaryRoute == nil)
            provider.isInBackground = false
            provider.startUpdatingLocation()
        }
        provider.beginJourneyTracking()
        precondition(provider.journeyTrackingDeadline != nil && env.timeout != nil)
        env.now += 1
        env.manager.send([env.fix(latitude: 39.95)])
        let firstGate = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
            location: provider.currentLocation, stations: stations, now: env.now, directory: directory)!
        precondition(!firstGate.confirmed)
        env.now += 10
        env.manager.send([env.fix(latitude: 39.95)])
        let gate = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
            location: provider.currentLocation, stations: stations, now: env.now, directory: directory)!
        precondition(gate.confirmed)
        let previousRevision = route.revision
        route = SharedRouteCoordinator.commit(originId: "B", destinationId: "A", expectedRevision: route.revision,
            arrival: true, observationAt: provider.currentLocation?.timestamp, now: env.now, directory: directory)!
        precondition(route.reason == "App arrival" && route.revision > previousRevision)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        precondition(env.manager.running)
        provider.reconcileSharedRoute(route, previousRevision: previousRevision)
        precondition(route.originId == "B" && route.destinationId == "A" && route.temporaryRoute == nil)
        precondition(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        precondition(provider.journeyTrackingDeadline == nil && env.timeout == nil && env.timeoutCancelled)

        let source = try String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        guard let start = source.range(of: "private func publishAppRoute()"),
              let end = source.range(of: "private func refreshDepartures()", range: start.upperBound..<source.endIndex) else {
            preconditionFailure("App route publication source was not found")
        }
        let publishing = String(source[start.lowerBound..<end.lowerBound])
        guard let reconcile = publishing.range(of: "locationProvider.reconcileSharedRoute(route, previousRevision: sharedRouteRevision)"),
              let adoption = publishing.range(of: "sharedRouteRevision = route.revision") else {
            preconditionFailure("App route publication must reconcile journey tracking before adopting the shared revision")
        }
        precondition(reconcile.upperBound < adoption.lowerBound,
            "Reconciliation must receive the previous revision, not the newly adopted revision")
        precondition(publishing.contains("if changed {\n            if route.completesJourney {\n                completedArrivalLocation = selectedStation(route.originId)?.location"),
            "Every completed arrival route must retain the station to suppress immediate journey rearming")
        precondition(source.contains("locationProvider.onLocationUpdate = { location in\n                    handleLocationUpdate(location)"),
            "Foreground and background arrival processing must use the direct per-fix callback")
        precondition(!source.contains(".onChange(of: locationProvider.currentLocation)"),
            "Published UI location changes must not process the last fix a second time")
        checkBatchedArrival(stations: stations, root: directory)
        print("App location integration checks passed: ordered batch arrival, real provider, compass action, return button state, relaunch, scene transitions and route-publication wiring")
    }

    private static func checkBatchedArrival(stations: [Station], root: URL) {
        for background in [false, true] {
            for delivery in ["separate", "batch", "unordered", "stale", "inaccurate-middle"] {
                let env = LocationTestEnvironment()
                let base = env.now
                let directory = root.appendingPathComponent("batch-\(background)-\(delivery)")
                let provider = env.provider()
                provider.startUpdatingLocation()
                provider.beginJourneyTracking()
                provider.isInBackground = background
                let route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                    now: base.addingTimeInterval(-60), directory: directory)!
                var observations = 0
                var arrivals = 0
                provider.onLocationUpdate = { location in
                    observations += 1
                    guard SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
                        location: location, stations: stations, now: env.now, directory: directory)?.confirmed == true else { return }
                    let arrived = SharedRouteCoordinator.commit(originId: "B", destinationId: "A",
                        expectedRevision: route.revision, arrival: true, observationAt: location.timestamp,
                        now: env.now, directory: directory)!
                    precondition(arrived.revision == route.revision + 1)
                    arrivals += 1
                    provider.endJourneyTracking()
                }
                env.now = base.addingTimeInterval(10)
                let first = env.fix(latitude: 39.95)
                if delivery == "separate" { env.manager.send([first]) }
                env.now = base.addingTimeInterval(delivery == "stale" ? 40 : 20)
                let second = env.fix(latitude: 39.95)
                switch delivery {
                case "separate": env.manager.send([second])
                case "unordered": env.manager.send([second, first, second, first])
                case "inaccurate-middle":
                    env.manager.send([first, env.fix(latitude: 39.95, secondsAgo: 5, accuracy: 200), second])
                default: env.manager.send([first, second])
                }
                precondition(observations == (delivery == "inaccurate-middle" ? 3 : 2))
                if delivery == "stale" || delivery == "inaccurate-middle" {
                    precondition(arrivals == 0, "Stale or contradictory batch samples cannot establish a stop")
                    precondition(SharedRouteCoordinator.current(directory: directory)?.revision == route.revision)
                    env.now += 10
                    env.manager.send([env.fix(latitude: 39.95)])
                }
                precondition(arrivals == 1, "Separate and batched stopped fixes must both confirm arrival")
                let arrived = SharedRouteCoordinator.current(directory: directory)!
                precondition(arrived.originId == "B" && arrived.destinationId == "A")
                precondition(provider.currentLocation?.timestamp == env.now)
                precondition(provider.journeyTrackingDeadline == nil && !env.manager.allowsBackgroundLocationUpdates)
                if background { precondition(!env.manager.running) }
                env.manager.send([env.fix(latitude: 39.95)])
                precondition(arrivals == 1 && SharedRouteCoordinator.current(directory: directory) == arrived,
                    "A repeated callback cannot complete the same arrival again")
                provider.onLocationUpdate = nil
            }
        }
    }
}
