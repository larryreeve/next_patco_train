import CoreLocation
import Observation
import XCTest
@testable import PATCOLogic

@MainActor
final class ServiceObservationTests: XCTestCase {
    func testLocationUpdatesDoNotInvalidateAuthorizationReaders() {
        let environment = LocationTestEnvironment()
        let provider = environment.provider()
        let locations = ObservationCounter()
        let permissions = ObservationCounter()
        withObservationTracking { _ = provider.currentLocation } onChange: { locations.increment() }
        withObservationTracking { _ = provider.authorizationStatus } onChange: { permissions.increment() }
        environment.manager.send([environment.fix()])
        XCTAssertEqual(locations.value, 1)
        XCTAssertEqual(permissions.value, 0)
        environment.manager.authorize(.denied)
        XCTAssertEqual(permissions.value, 1)
    }

    func testShortcutPreferenceDoesNotInvalidateSavedRouteReaders() {
        let suite = "observation-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults)
        let routes = ObservationCounter()
        let preference = ObservationCounter()
        withObservationTracking { _ = store.routes } onChange: { routes.increment() }
        withObservationTracking { _ = store.shortcutsEnabled } onChange: { preference.increment() }
        store.setShortcutsEnabled(false)
        XCTAssertEqual(preference.value, 1)
        XCTAssertEqual(routes.value, 0)
        XCTAssertTrue(store.save(name: "Commute", originId: "A", destinationId: "B"))
        XCTAssertEqual(routes.value, 1)
    }
}
