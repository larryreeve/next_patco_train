#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct AppLocationIntegrationCheck {
    static func run() throws {
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
        XCTAssertTrue(poll(&request) == .waiting)
        env.now += 3
        env.manager.send([env.fix(latitude: 39.95)])
        guard case .selected(let selected) = poll(&request) else { XCTFail("Fresh compass callback was not applied"); return }
        route = selected
        XCTAssertTrue(route.originId == "B" && route.destinationId == "A" && route.manual)
        XCTAssertTrue(poll(&request) == .selected(selected))
        XCTAssertTrue(SharedRouteCoordinator.current(directory: directory) == selected)
        env.now += 1
        env.manager.send([env.fix(latitude: 39.95, secondsAgo: 40)])
        var timeout = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        provider.requestLocation()
        env.manager.fail(.network)
        XCTAssertTrue(poll(&timeout) == .waiting)
        env.now += 8
        XCTAssertTrue(poll(&timeout) == .staleLocation)
        env.manager.send([env.fix()])
        XCTAssertTrue(poll(&timeout) == .staleLocation && SharedRouteCoordinator.current(directory: directory) == route)
        for reason in 0..<3 {
            var cancelledRequest = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
            XCTAssertTrue(poll(&cancelledRequest, foreground: reason != 0, today: reason != 1,
                              cancelled: reason == 2) == .cancelled)
            XCTAssertTrue(poll(&cancelledRequest) == .cancelled)
        }
        var permissionRequest = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        env.manager.authorize(.denied)
        XCTAssertTrue(poll(&permissionRequest) == .denied && provider.currentLocation == nil)
        XCTAssertTrue(SharedRouteCoordinator.current(directory: directory) == route)
        env.manager.authorize(.authorizedAlways)
        var racing = NearestStationSelectionRequest(expectedRevision: route.revision, requestedAt: env.now)
        route = SharedRouteCoordinator.reverse(expectedRevision: route.revision, now: env.now, directory: directory)!
        env.now += 1
        env.manager.send([env.fix(latitude: 39.965)])
        XCTAssertTrue(poll(&racing) == .routeChanged)
        XCTAssertTrue(SharedRouteCoordinator.current(directory: directory) == route)
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
            XCTAssertTrue(callbacks == 1)
            route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                departureLocation: explicitReturn ? nil : provider.currentLocation,
                requireDeparture: !explicitReturn, stations: stations, now: env.now, directory: directory)!
            XCTAssertTrue(route.originId == context.originId && route.destinationId == context.destinationId)
            XCTAssertTrue(route.manual == context.manual && route.temporaryRoute == nil)
            provider.isInBackground = false
            provider.startUpdatingLocation()
        }
        provider.beginJourneyTracking()
        XCTAssertTrue(provider.journeyTrackingDeadline != nil && env.timeout != nil)
        env.now += 1
        env.manager.send([env.fix(latitude: 39.95)])
        let firstGate = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
            location: provider.currentLocation, stations: stations, now: env.now, directory: directory)!
        XCTAssertTrue(!firstGate.confirmed)
        env.now += 10
        env.manager.send([env.fix(latitude: 39.95)])
        let gate = SharedRouteCoordinator.checkArrival(expectedRevision: route.revision,
            location: provider.currentLocation, stations: stations, now: env.now, directory: directory)!
        XCTAssertTrue(gate.confirmed)
        let previousRevision = route.revision
        route = SharedRouteCoordinator.commit(originId: "B", destinationId: "A", expectedRevision: route.revision,
            arrival: true, observationAt: provider.currentLocation?.timestamp, now: env.now, directory: directory)!
        XCTAssertTrue(route.reason == "App arrival" && route.revision > previousRevision)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        XCTAssertTrue(env.manager.running)
        provider.reconcileSharedRoute(route, previousRevision: previousRevision)
        XCTAssertTrue(route.originId == "B" && route.destinationId == "A" && route.temporaryRoute == nil)
        XCTAssertTrue(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        XCTAssertTrue(provider.journeyTrackingDeadline == nil && env.timeout == nil && env.timeoutCancelled)

        checkBatchedArrival(stations: stations, root: directory)
        print("App location integration checks passed: ordered batch arrival, real provider, compass action, return route state, relaunch and scene transitions")
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
                    XCTAssertTrue(arrived.revision == route.revision + 1)
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
                XCTAssertTrue(observations == (delivery == "inaccurate-middle" ? 3 : 2))
                if delivery == "stale" || delivery == "inaccurate-middle" {
                    XCTAssertTrue(arrivals == 0, "Stale or contradictory batch samples cannot establish a stop")
                    XCTAssertTrue(SharedRouteCoordinator.current(directory: directory)?.revision == route.revision)
                    env.now += 10
                    env.manager.send([env.fix(latitude: 39.95)])
                }
                XCTAssertTrue(arrivals == 1, "Separate and batched stopped fixes must both confirm arrival")
                let arrived = SharedRouteCoordinator.current(directory: directory)!
                XCTAssertTrue(arrived.originId == "B" && arrived.destinationId == "A")
                XCTAssertTrue(provider.currentLocation?.timestamp == env.now)
                XCTAssertTrue(provider.journeyTrackingDeadline == nil && !env.manager.allowsBackgroundLocationUpdates)
                if background { XCTAssertTrue(!env.manager.running) }
                env.manager.send([env.fix(latitude: 39.95)])
                XCTAssertTrue(arrivals == 1 && SharedRouteCoordinator.current(directory: directory) == arrived,
                    "A repeated callback cannot complete the same arrival again")
                provider.onLocationUpdate = nil
            }
        }
    }
}
