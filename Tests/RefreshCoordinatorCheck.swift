#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

struct RefreshCoordinatorCheck {
    @MainActor
    static func run() async {
        let coordinator = AppRefreshCoordinator()
        let gate = Gate()
        var locationRequests = 0
        var completed: Set<AppRefreshCoordinator.Lane> = []
        let refresh = Task { @MainActor in
            await coordinator.refresh(requestLocation: { locationRequests += 1 }, specialSchedules: {
                XCTAssertTrue(locationRequests == 1)
                await gate.wait()
            }, scheduleFeed: {
                completed.insert(.scheduleFeed)
            }, alerts: {
                completed.insert(.alerts)
            }, travelEstimates: {
                completed.insert(.travelEstimates)
            })
        }
        for _ in 0..<10_000 {
            if gate.entered && completed.count == 3 { break }
            await Task.yield()
        }
        XCTAssertTrue(gate.entered && completed.count == 3, "A stalled special schedule must not block the other lanes")
        XCTAssertTrue(coordinator.running == [.specialSchedules])
        await coordinator.refresh(requestLocation: { locationRequests += 1 }, specialSchedules: {
            XCTFail("Concurrent duplicate schedule request")
        }, scheduleFeed: {}, alerts: {}, travelEstimates: {})
        XCTAssertTrue(locationRequests == 2, "A second refresh must still request location")
        gate.release()
        await refresh.value
        XCTAssertTrue(!coordinator.isRefreshing)

        let cancelled = Task { @MainActor in
            await coordinator.refresh(requestLocation: { XCTFail("Cancelled refresh requested location") },
                specialSchedules: {}, scheduleFeed: {}, alerts: {}, travelEstimates: {})
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertTrue(!coordinator.isRefreshing)
        print("Refresh coordinator checks passed: independent lanes, location first, deduplication, retry and cancellation")
    }
}
