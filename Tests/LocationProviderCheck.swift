#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct LocationProviderCheck {
    static func run() {
        let env = LocationTestEnvironment()
        let provider = env.provider()
        XCTAssertTrue(env.manager.delegate === provider)
        XCTAssertTrue(env.manager.distanceFilter == 25)
        provider.requestLocation()
        XCTAssertTrue(env.manager.requests == 1 && provider.currentLocation == nil)
        env.now += 4
        env.manager.send([env.fix(secondsAgo: 2), env.fix()])
        XCTAssertTrue(provider.currentLocation?.timestamp == env.now && provider.lastUpdatedAt == env.now)
        env.manager.fail(.locationUnknown)
        XCTAssertTrue(provider.errorMessage != nil && env.errors == 1)
        env.manager.send([env.fix()])
        XCTAssertTrue(provider.errorMessage == nil)
        provider.startUpdatingLocation()
        XCTAssertTrue(env.manager.running)
        XCTAssertTrue(env.manager.distanceFilter == kCLDistanceFilterNone)
        XCTAssertTrue(env.manager.desiredAccuracy == kCLLocationAccuracyBest)
        XCTAssertTrue(!env.manager.pausesLocationUpdatesAutomatically, "Stationary foreground fixes must not be filtered or paused")
        provider.beginJourneyTracking()
        let deadline = provider.journeyTrackingDeadline!
        XCTAssertTrue(deadline == env.now.addingTimeInterval(7200))
        XCTAssertTrue(env.manager.allowsBackgroundLocationUpdates)
        XCTAssertTrue(env.manager.distanceFilter == kCLDistanceFilterNone)
        XCTAssertTrue(!env.manager.pausesLocationUpdatesAutomatically)
        provider.beginJourneyTracking()
        XCTAssertTrue(env.trackingChanges.count == 1)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        XCTAssertTrue(env.manager.running)
        XCTAssertTrue(!env.manager.pausesLocationUpdatesAutomatically, "Bounded journey tracking must continue through stops")
        var callbacks = 0
        provider.onLocationUpdate = { _ in callbacks += 1 }
        env.manager.send([env.fix()])
        XCTAssertTrue(callbacks == 1)
        env.now = deadline
        let timeout = env.timeout!
        timeout()
        XCTAssertTrue(env.timeoutCancelled && !env.manager.running)
        XCTAssertTrue(provider.journeyTrackingDeadline == nil && !env.manager.allowsBackgroundLocationUpdates)
        XCTAssertTrue(env.manager.distanceFilter == 25 && env.trackingChanges.count == 2)
        XCTAssertTrue(env.manager.pausesLocationUpdatesAutomatically)
        env.manager.authorize(.authorizedAlways)
        XCTAssertTrue(!env.manager.running)
        provider.isInBackground = false
        provider.startUpdatingLocation()
        provider.beginJourneyTracking()
        env.manager.authorize(.denied)
        XCTAssertTrue(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        XCTAssertTrue(provider.currentLocation == nil && provider.lastUpdatedAt == nil && env.cacheClears == 1)
        XCTAssertTrue(provider.journeyTrackingDeadline == nil)
        let requests = env.manager.requests
        env.manager.send([env.fix()])
        provider.requestLocation()
        provider.beginJourneyTracking()
        XCTAssertTrue(provider.currentLocation == nil && env.manager.requests == requests)
        XCTAssertTrue(provider.journeyTrackingDeadline == nil)
        env.manager.authorize(.notDetermined)
        provider.requestLocation()
        XCTAssertTrue(env.manager.permissionRequests == 1)
        env.manager.authorize(.restricted)
        provider.startUpdatingLocation()
        XCTAssertTrue(!env.manager.running)
        env.manager.authorize(.authorizedAlways)
        provider.beginJourneyTracking()
        provider.endJourneyTracking()
        XCTAssertTrue(env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        XCTAssertTrue(env.manager.distanceFilter == kCLDistanceFilterNone && !env.manager.pausesLocationUpdatesAutomatically)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        XCTAssertTrue(!env.manager.running)
        XCTAssertTrue(env.manager.distanceFilter == 25 && env.manager.pausesLocationUpdatesAutomatically)
        for code in [CLError.Code.denied, .network, .headingFailure] {
            env.manager.fail(code)
            XCTAssertTrue(provider.errorMessage != nil)
        }
        let reloads = env.widgetReloads
        let changes = env.trackingChanges.count
        provider.endJourneyTracking()
        XCTAssertTrue(env.trackingChanges.count == changes + 1 && env.trackingChanges.last! == nil)
        XCTAssertTrue(env.widgetReloads == reloads)
        checkBatchDelivery()
        checkAdaptiveSampling()
        checkSharedRouteReconciliation()
        checkArrivalReloadOwnership()
        checkSessionExpiry()
        checkExpirationCheckBudget()
        checkTripTrackingBudget()
        print("Location provider checks passed: ordered batch delivery, delayed callbacks, errors, permissions, expiry, shared-route revision reconciliation and tracking cleanup")
    }

    private static func checkTripTrackingBudget() {
        let env = LocationTestEnvironment()
        let provider = env.provider()
        provider.startUpdatingLocation()
        provider.beginJourneyTracking()
        XCTAssertTrue(provider.journeyTrackingDeadline == env.now.addingTimeInterval(7200))
        env.session = JourneyProgressSession(key: "budget", deepLink: "", originName: "A", destinationName: "B",
            departure: env.now, arrival: env.now.addingTimeInterval(1200), stops: [])
        provider.beginJourneyTracking()
        let deadline = env.now.addingTimeInterval(1800)
        XCTAssertTrue(provider.journeyTrackingDeadline == deadline)
        let changes = env.trackingChanges.count
        env.now += 30
        provider.beginJourneyTracking()
        XCTAssertTrue(provider.journeyTrackingDeadline == deadline && env.trackingChanges.count == changes)
        env.now = deadline
        env.timeout?()
        XCTAssertTrue(provider.journeyTrackingDeadline == nil && !env.manager.allowsBackgroundLocationUpdates)
    }

    private static func checkExpirationCheckBudget() {
        let env = LocationTestEnvironment()
        let provider = env.provider()
        var delivered = 0
        provider.onLocationUpdate = { _ in delivered += 1 }
        for _ in 0..<30 {
            env.manager.send([env.fix()])
            env.now += 1
        }
        XCTAssertTrue(delivered == 30 && env.activityExpirations == 1,
                     "Throttle activity housekeeping, never arrival observations")
        env.manager.send([env.fix()])
        XCTAssertTrue(env.activityExpirations == 2 && delivered == 31)
    }

    private static func checkSessionExpiry() {
        let env = LocationTestEnvironment()
        env.session = JourneyProgressSession(key: "trip", deepLink: "", originName: "A", destinationName: "B",
            departure: env.now, arrival: env.now.addingTimeInterval(60), stops: [])
        let provider = env.provider()
        provider.startUpdatingLocation()
        provider.beginJourneyTracking()
        provider.isInBackground = true
        var route = SharedRouteCoordinator.Route(originId: "A", destinationId: "B", savedOriginId: "A",
            savedDestinationId: "B", revision: 1, updatedAt: env.now, reason: "App route", manual: false)
        route.journey = env.session
        if var session = route.journey {
            JourneyCoordinator.transition(&session, event: .expire)
            route.journey = session
        }
        provider.reconcileSharedRoute(route, previousRevision: 1)
        XCTAssertTrue(provider.journeyTrackingDeadline == nil && !env.manager.running,
                     "Session expiry must stop GPS even without a route revision change")
    }

    private static func checkArrivalReloadOwnership() {
        let env = LocationTestEnvironment()
        let provider = env.provider()
        provider.startUpdatingLocation()
        provider.beginJourneyTracking()
        provider.isInBackground = true
        let reloads = env.widgetReloads
        provider.endJourneyTracking(reloadWidgets: false)
        XCTAssertTrue(env.widgetReloads == reloads, "Arrival owns the consolidated reload")
        XCTAssertTrue(env.trackingChanges.last! == nil)
        XCTAssertTrue(env.timeoutCancelled && provider.journeyTrackingDeadline == nil)
        XCTAssertTrue(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        provider.isInBackground = false
        provider.beginJourneyTracking()
        let restartedReloads = env.widgetReloads
        provider.endJourneyTracking()
        XCTAssertTrue(env.widgetReloads == restartedReloads + 1,
                     "Standalone tracking cleanup must still refresh the widget")
    }

    private static func checkAdaptiveSampling() {
        let env = LocationTestEnvironment()
        let provider = env.provider()
        let station = Station(id: "A", code: "A", name: "Station", latitude: 39.98,
                              longitude: -75.16, zone: "1", url: "")
        provider.startUpdatingLocation()
        env.manager.send([env.fix(latitude: 40.02)])
        provider.beginJourneyTracking(stations: [station])
        provider.isInBackground = true
        XCTAssertTrue(env.manager.distanceFilter == 100)
        XCTAssertTrue(env.manager.desiredAccuracy == kCLLocationAccuracyNearestTenMeters)
        XCTAssertTrue(!env.manager.pausesLocationUpdatesAutomatically)
        env.manager.send([env.fix(latitude: 39.985)])
        XCTAssertTrue(env.manager.distanceFilter == kCLDistanceFilterNone)
        XCTAssertTrue(env.manager.desiredAccuracy == kCLLocationAccuracyBest)
        env.manager.send([env.fix(latitude: 40.02)])
        XCTAssertTrue(env.manager.distanceFilter == 100)
        provider.isInBackground = false
        XCTAssertTrue(env.manager.distanceFilter == kCLDistanceFilterNone)
        provider.isInBackground = true
        provider.endJourneyTracking()
        XCTAssertTrue(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
    }

    private static func checkBatchDelivery() {
        for background in [false, true] {
            let env = LocationTestEnvironment()
            let provider = env.provider()
            provider.isInBackground = background
            let first = env.fix(secondsAgo: 10)
            let latest = env.fix()
            var timestamps: [Date] = []
            provider.onLocationUpdate = { location in
                timestamps.append(location.timestamp)
                XCTAssertTrue(provider.currentLocation?.timestamp == latest.timestamp,
                    "UI location must stay on the newest fix while a batch is processed")
            }
            env.manager.send([latest, first, first, latest])
            XCTAssertTrue(timestamps == [first.timestamp, latest.timestamp],
                "Foreground and background must receive every distinct timestamp in chronological order")
            XCTAssertTrue(env.activityExpirations == 1 && provider.lastUpdatedAt == env.now)
            env.manager.send([])
            XCTAssertTrue(timestamps.count == 2 && provider.currentLocation?.timestamp == latest.timestamp,
                "An empty callback must not erase the current location")
            XCTAssertTrue(env.activityExpirations == 1)
            env.manager.authorize(.denied)
            env.manager.send([latest])
            XCTAssertTrue(timestamps.count == 2 && provider.currentLocation == nil,
                "Revoked permission must prevent batch delivery")
            provider.onLocationUpdate = nil
        }
    }

    private static func checkSharedRouteReconciliation() {
        func route(_ reason: String, at now: Date) -> SharedRouteCoordinator.Route {
            SharedRouteCoordinator.Route(originId: "B", destinationId: "A", savedOriginId: "B", savedDestinationId: "A",
                revision: 8, updatedAt: now, lastLocationAt: nil, reason: reason, manual: false,
                blockedArrivalDestinationId: nil)
        }
        let completionReasons = ["Background arrival", "Estimated arrival", "User confirmed arrival", "Return direction recovered; station arrival unconfirmed",
            "Manual reversal", "App arrival"]
        for reason in completionReasons {
            let env = LocationTestEnvironment()
            let provider = env.provider()
            provider.startUpdatingLocation()
            provider.beginJourneyTracking()
            let deadline = provider.journeyTrackingDeadline!
            provider.isInBackground = true
            provider.stopUpdatingLocation()
            XCTAssertTrue(env.manager.running && env.timeout != nil && !env.timeoutCancelled)
            let stops = env.manager.stops
            let trackingChanges = env.trackingChanges.count
            let reloads = env.widgetReloads
            let sharedRoute = route(reason, at: env.now)
            for previousRevision in [nil, 8, 9] as [Int?] {
                provider.reconcileSharedRoute(sharedRoute, previousRevision: previousRevision)
                XCTAssertTrue(env.manager.running && env.manager.stops == stops,
                    "\(reason) cannot stop tracking without a strictly newer known revision")
                XCTAssertTrue(provider.journeyTrackingDeadline == deadline && env.timeout != nil && !env.timeoutCancelled)
                XCTAssertTrue(env.manager.allowsBackgroundLocationUpdates && !env.manager.pausesLocationUpdatesAutomatically)
                XCTAssertTrue(env.trackingChanges.count == trackingChanges && env.widgetReloads == reloads)
            }
            provider.reconcileSharedRoute(sharedRoute, previousRevision: 7)
            XCTAssertTrue(!env.manager.running && env.manager.stops == stops + 1,
                "A newer \(reason) route must stop the injected background location manager")
            XCTAssertTrue(provider.journeyTrackingDeadline == nil && env.timeout == nil && env.timeoutCancelled,
                "Shared-route completion must cancel the journey timer and clear its deadline")
            XCTAssertTrue(!env.manager.allowsBackgroundLocationUpdates && env.manager.pausesLocationUpdatesAutomatically)
            XCTAssertTrue(env.manager.distanceFilter == 25)
            XCTAssertTrue(env.trackingChanges.count == trackingChanges + 1 && env.trackingChanges.last! == nil)
            XCTAssertTrue(env.widgetReloads == reloads + 1)
            for previousRevision in [nil, 7, 8, 9] as [Int?] {
                provider.reconcileSharedRoute(sharedRoute, previousRevision: previousRevision)
                XCTAssertTrue(env.manager.stops == stops + 1 && provider.journeyTrackingDeadline == nil)
                XCTAssertTrue(env.trackingChanges.count == trackingChanges + 1 && env.widgetReloads == reloads + 1,
                    "Reconciling without an active journey must be idempotent")
            }

            let idle = LocationTestEnvironment()
            let idleProvider = idle.provider()
            idleProvider.isInBackground = true
            idleProvider.reconcileSharedRoute(route(reason, at: idle.now), previousRevision: 7)
            XCTAssertTrue(idle.manager.starts == 0 && idle.manager.stops == 0)
            XCTAssertTrue(idleProvider.journeyTrackingDeadline == nil && idle.timeout == nil && !idle.timeoutCancelled)
            XCTAssertTrue(idle.trackingChanges.isEmpty && idle.widgetReloads == 0)
        }
        for reason in ["Manual selection", "App route", "Find nearest station", "Station departures selection", "Station route restored"] {
            let env = LocationTestEnvironment()
            let provider = env.provider()
            provider.startUpdatingLocation()
            provider.beginJourneyTracking()
            let deadline = provider.journeyTrackingDeadline!
            provider.isInBackground = true
            let stops = env.manager.stops
            let trackingChanges = env.trackingChanges.count
            let reloads = env.widgetReloads
            provider.reconcileSharedRoute(route(reason, at: env.now), previousRevision: 7)
            XCTAssertTrue(env.manager.running && env.manager.stops == stops,
                "A newer ordinary \(reason) route must not terminate the journey")
            XCTAssertTrue(provider.journeyTrackingDeadline == deadline && env.timeout != nil && !env.timeoutCancelled)
            XCTAssertTrue(env.manager.allowsBackgroundLocationUpdates && !env.manager.pausesLocationUpdatesAutomatically)
            XCTAssertTrue(env.trackingChanges.count == trackingChanges && env.widgetReloads == reloads)
            provider.endJourneyTracking()
        }
    }
}
