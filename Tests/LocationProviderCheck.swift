import Foundation
import CoreLocation

@main
struct LocationProviderCheck {
    static func main() {
        let env = LocationTestEnvironment()
        let provider = env.provider()
        precondition(env.manager.delegate === provider)
        precondition(env.manager.distanceFilter == 25)
        provider.requestLocation()
        precondition(env.manager.requests == 1 && provider.currentLocation == nil)
        env.now += 4
        env.manager.send([env.fix(secondsAgo: 2), env.fix()])
        precondition(provider.currentLocation?.timestamp == env.now && provider.lastUpdatedAt == env.now)
        env.manager.fail(.locationUnknown)
        precondition(provider.errorMessage != nil && env.errors == 1)
        env.manager.send([env.fix()])
        precondition(provider.errorMessage == nil)
        provider.startUpdatingLocation()
        precondition(env.manager.running)
        precondition(env.manager.distanceFilter == kCLDistanceFilterNone)
        precondition(env.manager.desiredAccuracy == kCLLocationAccuracyBest)
        precondition(!env.manager.pausesLocationUpdatesAutomatically, "Stationary foreground fixes must not be filtered or paused")
        provider.beginJourneyTracking()
        let deadline = provider.journeyTrackingDeadline!
        precondition(deadline == env.now.addingTimeInterval(7200))
        precondition(env.manager.allowsBackgroundLocationUpdates)
        precondition(env.manager.distanceFilter == kCLDistanceFilterNone)
        precondition(!env.manager.pausesLocationUpdatesAutomatically)
        provider.beginJourneyTracking()
        precondition(env.trackingChanges.count == 1)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        precondition(env.manager.running)
        precondition(!env.manager.pausesLocationUpdatesAutomatically, "Bounded journey tracking must continue through stops")
        var callbacks = 0
        provider.onLocationUpdate = { _ in callbacks += 1 }
        env.manager.send([env.fix()])
        precondition(callbacks == 1)
        env.now = deadline
        let timeout = env.timeout!
        timeout()
        precondition(env.timeoutCancelled && !env.manager.running)
        precondition(provider.journeyTrackingDeadline == nil && !env.manager.allowsBackgroundLocationUpdates)
        precondition(env.manager.distanceFilter == 25 && env.trackingChanges.count == 2)
        precondition(env.manager.pausesLocationUpdatesAutomatically)
        env.manager.authorize(.authorizedAlways)
        precondition(!env.manager.running)
        provider.isInBackground = false
        provider.startUpdatingLocation()
        provider.beginJourneyTracking()
        env.manager.authorize(.denied)
        precondition(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        precondition(provider.currentLocation == nil && provider.lastUpdatedAt == nil && env.cacheClears == 1)
        precondition(provider.journeyTrackingDeadline == nil)
        let requests = env.manager.requests
        env.manager.send([env.fix()])
        provider.requestLocation()
        provider.beginJourneyTracking()
        precondition(provider.currentLocation == nil && env.manager.requests == requests)
        precondition(provider.journeyTrackingDeadline == nil)
        env.manager.authorize(.notDetermined)
        provider.requestLocation()
        precondition(env.manager.permissionRequests == 1)
        env.manager.authorize(.restricted)
        provider.startUpdatingLocation()
        precondition(!env.manager.running)
        env.manager.authorize(.authorizedAlways)
        provider.beginJourneyTracking()
        provider.endJourneyTracking()
        precondition(env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        precondition(env.manager.distanceFilter == kCLDistanceFilterNone && !env.manager.pausesLocationUpdatesAutomatically)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        precondition(!env.manager.running)
        precondition(env.manager.distanceFilter == 25 && env.manager.pausesLocationUpdatesAutomatically)
        for code in [CLError.Code.denied, .network, .headingFailure] {
            env.manager.fail(code)
            precondition(provider.errorMessage != nil)
        }
        let reloads = env.widgetReloads
        let changes = env.trackingChanges.count
        provider.endJourneyTracking()
        precondition(env.trackingChanges.count == changes + 1 && env.trackingChanges.last! == nil)
        precondition(env.widgetReloads == reloads)
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
        precondition(provider.journeyTrackingDeadline == env.now.addingTimeInterval(7200))
        env.session = JourneyProgressSession(key: "budget", deepLink: "", originName: "A", destinationName: "B",
            departure: env.now, arrival: env.now.addingTimeInterval(1200), stops: [])
        provider.beginJourneyTracking()
        let deadline = env.now.addingTimeInterval(1800)
        precondition(provider.journeyTrackingDeadline == deadline)
        let changes = env.trackingChanges.count
        env.now += 30
        provider.beginJourneyTracking()
        precondition(provider.journeyTrackingDeadline == deadline && env.trackingChanges.count == changes)
        env.now = deadline
        env.timeout?()
        precondition(provider.journeyTrackingDeadline == nil && !env.manager.allowsBackgroundLocationUpdates)
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
        precondition(delivered == 30 && env.activityExpirations == 1,
                     "Throttle activity housekeeping, never arrival observations")
        env.manager.send([env.fix()])
        precondition(env.activityExpirations == 2 && delivered == 31)
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
        route.journey?.termination = .expired
        provider.reconcileSharedRoute(route, previousRevision: 1)
        precondition(provider.journeyTrackingDeadline == nil && !env.manager.running,
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
        precondition(env.widgetReloads == reloads, "Arrival owns the consolidated reload")
        precondition(env.trackingChanges.last! == nil)
        precondition(env.timeoutCancelled && provider.journeyTrackingDeadline == nil)
        precondition(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
        provider.isInBackground = false
        provider.beginJourneyTracking()
        let restartedReloads = env.widgetReloads
        provider.endJourneyTracking()
        precondition(env.widgetReloads == restartedReloads + 1,
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
        precondition(env.manager.distanceFilter == 100)
        precondition(env.manager.desiredAccuracy == kCLLocationAccuracyNearestTenMeters)
        precondition(!env.manager.pausesLocationUpdatesAutomatically)
        env.manager.send([env.fix(latitude: 39.985)])
        precondition(env.manager.distanceFilter == kCLDistanceFilterNone)
        precondition(env.manager.desiredAccuracy == kCLLocationAccuracyBest)
        env.manager.send([env.fix(latitude: 40.02)])
        precondition(env.manager.distanceFilter == 100)
        provider.isInBackground = false
        precondition(env.manager.distanceFilter == kCLDistanceFilterNone)
        provider.isInBackground = true
        provider.endJourneyTracking()
        precondition(!env.manager.running && !env.manager.allowsBackgroundLocationUpdates)
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
                precondition(provider.currentLocation?.timestamp == latest.timestamp,
                    "UI location must stay on the newest fix while a batch is processed")
            }
            env.manager.send([latest, first, first, latest])
            precondition(timestamps == [first.timestamp, latest.timestamp],
                "Foreground and background must receive every distinct timestamp in chronological order")
            precondition(env.activityExpirations == 1 && provider.lastUpdatedAt == env.now)
            env.manager.send([])
            precondition(timestamps.count == 2 && provider.currentLocation?.timestamp == latest.timestamp,
                "An empty callback must not erase the current location")
            precondition(env.activityExpirations == 1)
            env.manager.authorize(.denied)
            env.manager.send([latest])
            precondition(timestamps.count == 2 && provider.currentLocation == nil,
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
            precondition(env.manager.running && env.timeout != nil && !env.timeoutCancelled)
            let stops = env.manager.stops
            let trackingChanges = env.trackingChanges.count
            let reloads = env.widgetReloads
            let sharedRoute = route(reason, at: env.now)
            for previousRevision in [nil, 8, 9] as [Int?] {
                provider.reconcileSharedRoute(sharedRoute, previousRevision: previousRevision)
                precondition(env.manager.running && env.manager.stops == stops,
                    "\(reason) cannot stop tracking without a strictly newer known revision")
                precondition(provider.journeyTrackingDeadline == deadline && env.timeout != nil && !env.timeoutCancelled)
                precondition(env.manager.allowsBackgroundLocationUpdates && !env.manager.pausesLocationUpdatesAutomatically)
                precondition(env.trackingChanges.count == trackingChanges && env.widgetReloads == reloads)
            }
            provider.reconcileSharedRoute(sharedRoute, previousRevision: 7)
            precondition(!env.manager.running && env.manager.stops == stops + 1,
                "A newer \(reason) route must stop the injected background location manager")
            precondition(provider.journeyTrackingDeadline == nil && env.timeout == nil && env.timeoutCancelled,
                "Shared-route completion must cancel the journey timer and clear its deadline")
            precondition(!env.manager.allowsBackgroundLocationUpdates && env.manager.pausesLocationUpdatesAutomatically)
            precondition(env.manager.distanceFilter == 25)
            precondition(env.trackingChanges.count == trackingChanges + 1 && env.trackingChanges.last! == nil)
            precondition(env.widgetReloads == reloads + 1)
            for previousRevision in [nil, 7, 8, 9] as [Int?] {
                provider.reconcileSharedRoute(sharedRoute, previousRevision: previousRevision)
                precondition(env.manager.stops == stops + 1 && provider.journeyTrackingDeadline == nil)
                precondition(env.trackingChanges.count == trackingChanges + 1 && env.widgetReloads == reloads + 1,
                    "Reconciling without an active journey must be idempotent")
            }

            let idle = LocationTestEnvironment()
            let idleProvider = idle.provider()
            idleProvider.isInBackground = true
            idleProvider.reconcileSharedRoute(route(reason, at: idle.now), previousRevision: 7)
            precondition(idle.manager.starts == 0 && idle.manager.stops == 0)
            precondition(idleProvider.journeyTrackingDeadline == nil && idle.timeout == nil && !idle.timeoutCancelled)
            precondition(idle.trackingChanges.isEmpty && idle.widgetReloads == 0)
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
            precondition(env.manager.running && env.manager.stops == stops,
                "A newer ordinary \(reason) route must not terminate the journey")
            precondition(provider.journeyTrackingDeadline == deadline && env.timeout != nil && !env.timeoutCancelled)
            precondition(env.manager.allowsBackgroundLocationUpdates && !env.manager.pausesLocationUpdatesAutomatically)
            precondition(env.trackingChanges.count == trackingChanges && env.widgetReloads == reloads)
            provider.endJourneyTracking()
        }
    }
}
