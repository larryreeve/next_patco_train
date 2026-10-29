#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct WidgetBatteryCheck {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: nil, now: now, manual: false))
        for elapsed in [0.0, 1, 30, 179, 299] {
            XCTAssertTrue(!WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now, now: now.addingTimeInterval(elapsed), manual: false))
            XCTAssertTrue(WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now, now: now.addingTimeInterval(elapsed), manual: true))
        }
        XCTAssertTrue(WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now, now: now.addingTimeInterval(300), manual: false))
        XCTAssertTrue(WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now, now: now.addingTimeInterval(-1), manual: false))
        XCTAssertTrue(!WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now,
            now: now.addingTimeInterval(179), manual: false, lastSuccessfulLocation: now))
        XCTAssertTrue(WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now,
            now: now.addingTimeInterval(181), manual: false, lastSuccessfulLocation: now))
        XCTAssertTrue(!WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now,
            now: now.addingTimeInterval(181), manual: false, lastSuccessfulLocation: now.addingTimeInterval(-1)),
            "An older cached fix must not shorten failed-attempt backoff")
        let refresh = WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true, locationTimestamp: now)
        XCTAssertTrue(refresh.date < now.addingTimeInterval(900))
        XCTAssertTrue(WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: now, now: refresh.date,
            manual: false, lastSuccessfulLocation: now), "The next freshness refresh must not be blocked by GPS cooldown")
        let source = try SourceInspection.widget()
        let snapshot = source.components(separatedBy: "func snapshot(for configuration:")[1].components(separatedBy: "func timeline(for")[0]
        XCTAssertTrue(snapshot.contains("authorizedCachedLocation") && !snapshot.contains("WidgetLocationProvider.currentLocation"))
        XCTAssertTrue(snapshot.contains("loadedStore: store") && snapshot.contains("resolvedRoute:"),
                     "Home previews must bypass route resolution and shared-state publication")
        let lockSnapshot = source.components(separatedBy: "func getSnapshot(in context:")[1].components(separatedBy: "func getTimeline(in context:")[0]
        for forbidden in ["makeCurrentTimeline(", "selectedRoute(", "updateSharedTrip(", "reloadAllTimelines(", "WidgetLocationProvider.currentLocation"] {
            XCTAssertTrue(!lockSnapshot.contains(forbidden), "Lock Screen preview must be read-only: \(forbidden)")
        }
        XCTAssertTrue(lockSnapshot.contains("dates: [now]") && lockSnapshot.contains("completion(PATCOLockScreenEntry("))
        let interactive = source.components(separatedBy: "private enum WidgetInteractiveRefresh {")[1].components(separatedBy: "struct RefreshPATCOWidgetIntent:")[0]
        XCTAssertTrue(!interactive.contains("WidgetCenter.shared.reload"))
        XCTAssertTrue(interactive.contains("force: true, reloadWidgets: false"))
        for (start, end) in [("struct RefreshPATCOWidgetIntent:", "struct RefreshPATCOLockScreenWidgetIntent:"),
                             ("struct ReversePATCOWidgetRouteIntent:", "struct TogglePATCOReachabilityModeIntent:"),
                             ("struct TogglePATCOReachabilityModeIntent:", "struct NextPATCOTrainWidgetEntryView:")] {
            let action = source.components(separatedBy: start)[1].components(separatedBy: end)[0]
            XCTAssertTrue(action.components(separatedBy: "WidgetCenter.shared.reload").count == 2,
                         "Each action should have exactly one explicit reload: \(start)")
            XCTAssertTrue(action.contains("WidgetActionProgress.finish(progress)\n            SharedWidgetDiagnostics.recordReloadRequest"))
        }
        let homeTimeline = source.components(separatedBy: "private func makeHomeTimeline(")[1].components(separatedBy: "func refreshTravelTimeEstimate(")[0]
        XCTAssertTrue(!homeTimeline.contains("recordHomeWidgetRoute("))
        XCTAssertTrue(homeTimeline.contains("reloadKind: \"NextPATCOLockScreenWidget\""))
        print("Widget battery checks passed: cache-only previews, bounded automatic GPS retries, manual bypass and clock rollback")
    }
}
