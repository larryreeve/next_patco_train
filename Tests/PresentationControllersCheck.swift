#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation
import MapKit
import Observation

struct PresentationControllersCheck {
    @MainActor
    private final class ObservationProbe {
        var changed = false
    }

    @MainActor
    static func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let location = CLLocation(latitude: origin.latitude + 0.008, longitude: origin.longitude)
        var context = TravelEstimateController.Context(isActive: true, isViewingToday: true,
            originId: origin.id, routeRevision: 10, location: location, authorization: .authorizedAlways)
        let suite = "PresentationControllersCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var requests = 0
        let cache = TravelEstimateController.Cache(defaults: defaults, directory: directory)
        let controller = TravelEstimateController(now: { now }, cache: cache, calculate: { request in
            requests += 1
            XCTAssertTrue(request.transportType == .automobile || request.transportType == .walking)
            return .init(expectedTravelTime: 121, distance: 1000)
        })
        let driving = ObservationProbe()
        let walking = ObservationProbe()
        withObservationTracking {
            _ = controller.driveTimeEstimate
        } onChange: {
            MainActor.assumeIsolated { driving.changed = true }
        }
        withObservationTracking {
            _ = controller.walkingTimeEstimate
        } onChange: {
            MainActor.assumeIsolated { walking.changed = true }
        }
        await controller.refreshDriveTimeEstimate(origin: origin, force: false, context: { context })
        XCTAssertTrue(driving.changed, "Driving estimates must notify their readers")
        XCTAssertTrue(!walking.changed, "Driving estimates must not invalidate walking-only readers")
        XCTAssertTrue(controller.driveTimeEstimate?.minutes == 3)
        XCTAssertTrue(controller.driveTimeEstimate?.fetchedAt == now)
        XCTAssertTrue(!controller.drivingEstimateInFlight)
        await controller.refreshDriveTimeEstimate(origin: origin, force: false, context: { context })
        XCTAssertTrue(requests == 1, "Fresh estimate must avoid another network request")
        now.addTimeInterval(300)
        await controller.refreshDriveTimeEstimate(origin: origin, force: false, context: { context })
        XCTAssertTrue(requests == 2, "Injected clock must also expire cached estimates")
        await controller.refreshWalkingTimeEstimate(origin: origin, force: true, context: { context })
        XCTAssertTrue(controller.walkingTimeEstimate?.routeDistanceMeters == 1000)
        XCTAssertTrue(controller.driveTimeEstimate?.routeDistanceMeters == nil)

        for change in 0..<4 {
            context.routeRevision = 10
            context.location = location
            context.authorization = .authorizedAlways
            context.isViewingToday = true
            let obsolete = TravelEstimateController(now: { now }, cache: cache, calculate: { _ in
                switch change {
                case 0: context.routeRevision = 11
                case 1: context.location = CLLocation(latitude: origin.latitude + 0.02, longitude: origin.longitude)
                case 2: context.authorization = .denied
                default: context.isViewingToday = false
                }
                return .init(expectedTravelTime: 600, distance: 1000)
            })
            await obsolete.refreshDriveTimeEstimate(origin: origin, force: true, context: { context })
            XCTAssertTrue(obsolete.driveTimeEstimate == nil, "Obsolete response must not publish")
        }

        context.routeRevision = 10
        context.location = location
        context.authorization = .authorizedAlways
        context.isViewingToday = true
        enum NetworkFailure: Error { case offline }
        let failed = TravelEstimateController(now: { now }, cache: cache, calculate: { _ in
            // A competing widget response must survive this older request's failure.
            cache.save(mode: .driving, origin: origin, currentLocation: location, minutes: 7,
                       fetchedAt: now.addingTimeInterval(1), requestStartedAt: now.addingTimeInterval(1))
            throw NetworkFailure.offline
        })
        await failed.refreshDriveTimeEstimate(origin: origin, force: true, context: { context })
        XCTAssertTrue(failed.driveTimeEstimate == nil && !failed.drivingEstimateInFlight)
        XCTAssertTrue(cache.estimate(mode: .driving, origin: origin, currentLocation: location,
                                   now: now.addingTimeInterval(2))?.minutes == 7)

        let staleFailure = TravelEstimateController(now: { now }, cache: cache, calculate: { _ in
            context.routeRevision = 11
            throw NetworkFailure.offline
        })
        staleFailure.driveTimeEstimate = controller.driveTimeEstimate
        await staleFailure.refreshDriveTimeEstimate(origin: origin, force: true, context: { context })
        XCTAssertTrue(staleFailure.driveTimeEstimate?.minutes == 3, "Obsolete failure must not erase the displayed estimate")

        var events: [String] = []
        var active = true
        var sleeper: CheckedContinuation<Void, Error>?
        let reloads = WidgetReloadCoordinator(now: { now }, sleep: { _ in
            try await withCheckedThrowingContinuation { sleeper = $0 }
        }, reload: { events.append("reload") })
        func request(_ force: Bool = false) {
            reloads.request(reason: "test", force: force, isActive: { active }, publish: { _ in events.append("publish") })
        }
        request()
        XCTAssertTrue(events == ["publish", "reload"], "Publish must precede reload")
        request()
        request()
        XCTAssertTrue(reloads.pendingAt == now.addingTimeInterval(60))
        while sleeper == nil { await Task.yield() }
        now.addTimeInterval(61)
        sleeper?.resume(); sleeper = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(events.count == 4, "Repeated requests must produce one trailing reload")
        active = false
        request()
        XCTAssertTrue(events.count == 4)
        now.addTimeInterval(3)
        request(true)
        XCTAssertTrue(events.count == 6, "Forced route changes can reload in background")
        now.addTimeInterval(-100)
        request(true)
        XCTAssertTrue(events.count == 8, "Clock rollback must not indefinitely throttle reloads")
        print("Presentation controller checks passed: estimates, stale responses, clock, isolated cache, reload ordering and coalescing")
    }
}
