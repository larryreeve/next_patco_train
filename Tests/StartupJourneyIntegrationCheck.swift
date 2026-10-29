#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct StartupJourneyIntegrationCheck {
    @MainActor
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = LocationTestEnvironment()
        let provider = env.provider()
        let coordinator = AppRefreshCoordinator()
        let route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: env.now.addingTimeInterval(-1), directory: root)!
        let session = JourneyProgressSession(key: "startup-trip",
            deepLink: "patconext://departure?origin=A&destination=B&departure=1800000000",
            originName: "A", destinationName: "B", departure: env.now,
            arrival: env.now.addingTimeInterval(600), stops: [])
        _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: route.revision, now: env.now, directory: root)
        env.session = session
        // These are the same entry points used by the app, with the real provider and a fake OS manager.
        provider.refreshForForeground()
        XCTAssertTrue(env.manager.running && env.manager.requests == 1)
        var scheduleStarted = false
        var scheduleFinished = false
        var release: CheckedContinuation<Void, Never>?
        let refresh = Task { @MainActor in
            await coordinator.refresh(requestLocation: { provider.requestLocation() }, specialSchedules: {
                await withCheckedContinuation { continuation in
                    release = continuation
                    scheduleStarted = true
                }
                scheduleFinished = true
            }, scheduleFeed: {}, alerts: {}, travelEstimates: {})
        }
        for _ in 0..<10_000 {
            if scheduleStarted { break }
            await Task.yield()
        }
        XCTAssertTrue(scheduleStarted && !scheduleFinished)
        env.manager.send([env.fix()])
        XCTAssertTrue(provider.currentLocation?.timestamp == env.now)
        provider.beginJourneyTracking()
        XCTAssertTrue(provider.journeyTrackingDeadline != nil)
        provider.isInBackground = true
        provider.stopUpdatingLocation()
        XCTAssertTrue(env.manager.running, "A trip without a Live Activity must continue in background")
        env.now += 120
        let requests = env.manager.requests
        provider.refreshForForeground()
        XCTAssertTrue(env.manager.requests > requests && !provider.isInBackground && !scheduleFinished)
        env.manager.send([env.fix(accuracy: 1414)])
        XCTAssertTrue(SharedRouteCoordinator.current(directory: root)?.journey?.state == .tracking,
                     "Signal loss cannot cancel or complete the journey")
        _ = SharedRouteCoordinator.cancelJourney(key: session.key, directory: root)
        env.session = SharedRouteCoordinator.current(directory: root)?.journey
        provider.endJourneyTracking()
        XCTAssertTrue(provider.journeyTrackingDeadline == nil)
        _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: route.revision, now: env.now, directory: root)
        XCTAssertTrue(SharedRouteCoordinator.current(directory: root)?.journey?.state == .cancelled)
        let restoredProvider = env.provider()
        restoredProvider.refreshForForeground()
        XCTAssertTrue(restoredProvider.journeyTrackingDeadline == nil, "Relaunch must not revive a cancelled trip")
        env.manager.authorize(.denied)
        let deniedRequests = env.manager.requests
        restoredProvider.refreshForForeground()
        XCTAssertTrue(env.manager.requests == deniedRequests && !env.manager.running)
        release?.resume()
        await refresh.value
        XCTAssertTrue(scheduleFinished && !coordinator.isRefreshing)
        print("Startup journey integration checks passed: startup/foreground GPS during blocked network, background tracking without ActivityKit, signal loss, cancellation and relaunch")
    }
}
