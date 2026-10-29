import XCTest

/// Serial execution is intentional: legacy checks exercise process-wide shared caches.
@MainActor
final class RegressionTests: XCTestCase {
    override class func tearDown() {
        MainActor.assumeIsolated { ProcessCheckRunner.cleanUp() }
        super.tearDown()
    }

    override func setUpWithError() throws {
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(TestPaths.repository.path))
    }

    func testAppLocationIntegrationCheck() throws { try AppLocationIntegrationCheck.run() }
    func testCompassFallbackCheck() throws { try CompassFallbackCheck.run() }
    func testConservativeStationCheck() throws { try ConservativeStationCheck.run() }
    func testCurrentLocationCacheCheck() throws { try CurrentLocationCacheCheck.run() }
    func testCurrentStationCheck() { CurrentStationCheck.run() }
    func testDSTScheduleCheck() throws { try DSTScheduleCheck.run() }
    func testDestinationArrivalCheck() { DestinationArrivalCheck.run() }
    func testDestinationGeofenceCheck() throws { try DestinationGeofenceCheck.run() }
    func testDiagnosticsLayoutCheck() throws { try DiagnosticsLayoutCheck.run() }
    func testEarlierDeparturesCheck() throws { try EarlierDeparturesCheck.run() }
    func testEstimatedArrivalCheck() throws { try EstimatedArrivalCheck.run() }
    func testFeedValidationCheck() throws { try FeedValidationCheck.run() }
    func testGTFSUpdateServiceCheck() async throws { try await GTFSUpdateServiceCheck.run() }
    func testHomeReachabilityCheck() throws { try HomeReachabilityCheck.run() }
    func testJourneyCoordinatorCheck() throws { try JourneyCoordinatorCheck.run() }
    func testJourneyLifecycleCheck() throws { try JourneyLifecycleCheck.run() }
    func testJourneyLocationControllerCheck() throws { try JourneyLocationControllerCheck.run() }
    func testLocationBoundaryCheck() { LocationBoundaryCheck.run() }
    func testLocationProviderCheck() { LocationProviderCheck.run() }
    func testLocationRaceCheck() throws { try ProcessCheckRunner.run("LocationRaceCheck") }
    func testLocationRandomizedCheck() { LocationRandomizedCheck.run() }
    func testLocationRegressionCheck() throws { try LocationRegressionCheck.run() }
    func testLocationTripReplayCheck() throws { try LocationTripReplayCheck.run() }
    func testLockScreenRouteSyncCheck() throws { try LockScreenRouteSyncCheck.run() }
    func testMidnightScheduleCheck() throws { try MidnightScheduleCheck.run() }
    func testMorningRideReplayCheck() throws { try MorningRideReplayCheck.run() }
    func testPreciseArrivalCheck() throws { try PreciseArrivalCheck.run() }
    func testPresentationControllersCheck() async throws { try await PresentationControllersCheck.run() }
    func testPresentationRefreshCheck() throws { try PresentationRefreshCheck.run() }
    func testRefreshCoordinatorCheck() async { await RefreshCoordinatorCheck.run() }
    func testReturnDirectionCheck() throws { try ReturnDirectionCheck.run() }
    func testRoutePersistenceCheck() throws { try RoutePersistenceCheck.run() }
    func testRoutePreferencesCheck() { RoutePreferencesCheck.run() }
    func testRouteProcessRecoveryCheck() throws { try ProcessCheckRunner.run("RouteProcessRecoveryCheck") }
    func testRouteTransitionCheck() throws { try RouteTransitionCheck.run() }
    func testSavedRoutesCheck() throws { try SavedRoutesCheck.run() }
    func testSharedJourneyCheck() throws { try SharedJourneyCheck.run() }
    func testSharedRouteCheck() throws { try ProcessCheckRunner.run("SharedRouteCheck") }
    func testSpecialScheduleParsingCheck() async throws { try await SpecialScheduleParsingCheck.run() }
    func testStartupJourneyIntegrationCheck() async throws { try await StartupJourneyIntegrationCheck.run() }
    func testStructuredDiagnosticsCheck() throws { try StructuredDiagnosticsCheck.run() }
    func testTravelEstimateCacheCheck() throws { try TravelEstimateCacheCheck.run() }
    func testTripArrivalEstimateCheck() throws { try TripArrivalEstimateCheck.run() }
    func testTripBackfillCheck() throws { try TripBackfillCheck.run() }
    func testTripDetailPresentationCheck() throws { try TripDetailPresentationCheck.run() }
    func testTripMapFocusCheck() throws { try TripMapFocusCheck.run() }
    func testTripMapPositionCheck() throws { try TripMapPositionCheck.run() }
    func testTripProgressCheck() throws { try TripProgressCheck.run() }
    func testTripSpeedCheck() throws { try TripSpeedCheck.run() }
    func testUXRecoveryCheck() async throws { try await UXRecoveryCheck.run() }
    func testUndergroundDepartureCheck() { UndergroundDepartureCheck.run() }
    func testUndergroundRecoveryCheck() throws { try UndergroundRecoveryCheck.run() }
    func testUrbanStationArrivalCheck() throws { try UrbanStationArrivalCheck.run() }
    func testWalkingRouteDistanceCheck() throws { try WalkingRouteDistanceCheck.run() }
    func testWidgetActionProgressCheck() throws { try ProcessCheckRunner.run("WidgetActionProgressCheck") }
    func testWidgetBatteryCheck() throws { try WidgetBatteryCheck.run() }
    func testWidgetReturnDirectionCheck() throws { try WidgetReturnDirectionCheck.run() }
    func testWidgetTimelineCheck() { WidgetTimelineCheck.run() }
}

enum TestPaths {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}
