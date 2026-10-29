#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct RoutePreferencesCheck {
    static func run() {
        let suite = "patco.route-preferences.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var selected: (String, String)?
        let preferences = RoutePreferences(defaults: defaults, now: { now }, currentRoute: { nil },
            selectRoute: { origin, destination, _, _ in selected = (origin, destination) })
        XCTAssertTrue(preferences.savedRoute() == nil)
        preferences.save(originId: "2", destinationId: "14")
        XCTAssertTrue(selected?.0 == "2" && selected?.1 == "14")
        XCTAssertTrue(preferences.savedRoute()?.destinationId == "14")
        preferences.saveTemporary(originId: "11", destinationId: "14")
        preferences.saveJourneyDirection(destinationId: "14")
        preferences.saveManualStationSelection(stationId: "11")
        XCTAssertTrue(preferences.temporaryRoute()?.originId == "11")
        XCTAssertTrue(preferences.manuallySelectedAtStationId() == "11")
        now.addTimeInterval(4 * 3600 + 1)
        XCTAssertTrue(preferences.journeyDestinationId() == nil)
        XCTAssertTrue(defaults.object(forKey: "journeyDirectionSavedAt") == nil)
        XCTAssertTrue(preferences.temporaryRoute() != nil)
        now.addTimeInterval(8 * 3600)
        XCTAssertTrue(preferences.temporaryRoute() == nil)
        preferences.clearTemporary()
        preferences.clearManualStationSelection()
        XCTAssertTrue(preferences.manuallySelectedAtStationId() == nil)
        XCTAssertTrue(preferences.savedRoute()?.originId == "2", "Clearing transient selection preserves saved route")
        print("Route preference checks passed: isolated storage, route selection, expiry and cleanup")
    }
}
