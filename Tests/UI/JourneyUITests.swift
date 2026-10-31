import XCTest

@MainActor
final class JourneyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-arrivalScreenPreview", "-journeyUITests"]
        app.launchEnvironment["PATCO_TEST_ROUTE_DIRECTORY"] = "patco-ui-\(UUID().uuidString)"
        app.launchEnvironment["PATCO_UI_NOW"] = String(floor(Date().timeIntervalSince1970))
    }

    override func tearDown() {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        super.tearDown()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            // Swipe beside the map so its pan gesture does not consume list scrolling.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25)))
        }
        XCTAssertTrue(element.isHittable, "Control should be reachable by scrolling")
    }

    func testNormalLaunchRespondsToDepartureSelectionAndRelaunch() {
        // Do not use the detail-preview entry point: this must exercise ContentView.
        app.launchArguments = ["-hasSeenLocationPermissionExplanation", "YES"]
        for iteration in 0..<2 {
            app.launch()
            let row = app.buttons.matching(identifier: "departure.row").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Normal startup must finish rendering")
            reveal(row)
            row.tap()
            let close = app.buttons["Close trip details"]
            XCTAssertTrue(close.waitForExistence(timeout: 5), "The departure list must respond to taps")
            close.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            if iteration == 0 { app.terminate() }
        }
    }

    func testHomeRouteControlsAndDatePicker() {
        app.launchArguments = ["-hasSeenLocationPermissionExplanation", "YES"]
        app.launch()
        let summary = app.buttons["home.route.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        let originalRoute = summary.label
        let reverse = app.buttons["Reverse route"]
        XCTAssertTrue(reverse.isEnabled)
        reverse.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", originalRoute),
            object: summary)], timeout: 5), .completed)
        reverse.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", originalRoute),
            object: summary)], timeout: 5), .completed)

        let edit = app.buttons["home.route.edit"]
        edit.tap()
        XCTAssertTrue(app.staticTexts["From"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["To"].exists)
        edit.tap()
        XCTAssertFalse(app.staticTexts["From"].exists)

        let date = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose departure date,'")).firstMatch
        date.tap()
        let close = app.buttons["Close date picker"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        date.tap()
        XCTAssertTrue(app.buttons["Today"].waitForExistence(timeout: 5))
        app.buttons["Today"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "departure.row").firstMatch.waitForExistence(timeout: 5))
    }

    func testTrackingWithoutLockScreenSurvivesRelaunchAndCancellation() {
        app.launchArguments += ["-untrackedTrackingPreview", "-beforeTripTrackingPreview"]
        app.launch()
        let start = app.buttons["trip.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        reveal(start)
        start.tap()
        XCTAssertTrue(app.buttons["trip.stop"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["trip.lockScreen"].value as? String, "0")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["trip.stop"].waitForExistence(timeout: 10))
        reveal(app.buttons["trip.stop"])
        app.buttons["trip.stop"].tap()
        // Compact confirmation popovers dismiss by tapping outside; sheets expose Cancel.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.staticTexts["Departure Details"].tap() }
        XCTAssertTrue(app.buttons["trip.stop"].exists, "Dismissing confirmation must keep tracking")
        app.buttons["trip.stop"].tap()
        app.sheets.buttons["Cancel tracking"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Cancellation must survive relaunch")
        XCTAssertFalse(app.buttons["trip.stop"].exists)
    }

    func testRoutePickerCommitsSelectedEndpoints() {
        app.launchArguments = ["-hasSeenLocationPermissionExplanation", "YES"]
        app.launch()
        let summary = app.buttons["home.route.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        let origin = summary.label.hasPrefix("Woodcrest to") ? "Ashland" : "Woodcrest"
        let destination = summary.label.hasSuffix("to Haddonfield") ? "Westmont" : "Haddonfield"
        app.buttons["home.route.edit"].tap()
        let from = app.buttons["home.route.from"]
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        from.tap()
        app.buttons["home.route.from.\(origin)"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "\(origin) to"),
            object: summary)], timeout: 5), .completed)
        // Route selection may collapse the editor when station detection updates.
        if !app.buttons["home.route.to"].isHittable { app.buttons["home.route.edit"].tap() }
        app.buttons["home.route.to"].tap()
        app.buttons["home.route.to.\(destination)"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "\(origin) to \(destination)"),
            object: summary)], timeout: 5), .completed)
    }

    func testFaresDisclosureIdentifiesBothStations() {
        app.launchArguments += ["-untrackedTrackingPreview", "-beforeTripTrackingPreview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Scheduled Arrival"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Estimated Arrival"].exists)
        let fares = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fares & accessibility'")).firstMatch
        reveal(fares)
        let departureInfo = app.buttons["Station information for departure, Ashland"]
        let destinationInfo = app.buttons["Station information for destination, 15/16th and Locust"]
        XCTAssertFalse(departureInfo.exists)
        fares.tap()
        reveal(destinationInfo)
        XCTAssertTrue(departureInfo.exists)
        XCTAssertTrue(destinationInfo.isHittable)
    }

    func testScheduledAndEstimatedTimesAndMapFollowing() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Estimated Arrival"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Scheduled Departure"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scheduled arrival:'")).firstMatch.exists)
        let follow = app.buttons["trip.follow"]
        reveal(follow)
        follow.tap()
        XCTAssertTrue(waitForValue("Following", on: follow))
        let map = app.maps.firstMatch
        reveal(map)
        map.swipeLeft()
        XCTAssertTrue(waitForValue("Paused", on: follow))
        reveal(follow)
        follow.tap()
        XCTAssertTrue(waitForValue("Following", on: follow))
    }

    func testSignalLossDoesNotInventAnETA() {
        app.launchArguments += ["-staleTrackingPreview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Scheduled Arrival"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Estimated Arrival"].exists)
        reveal(app.staticTexts["Live location unavailable"])
        XCTAssertTrue(app.staticTexts["Live location unavailable"].exists)
        XCTAssertTrue(app.buttons["trip.stop"].exists)
    }

    func testArrivalConfirmationPersistsCompletion() {
        app.launch()
        let arrived = app.buttons["I've arrived"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 10))
        reveal(arrived)
        arrived.tap()
        app.sheets.buttons["I've arrived"].tap()
        XCTAssertTrue(app.buttons["Return to departures"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Return to departures"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["trip.stop"].exists)
    }

    func testAccessibilityTextSizeKeepsControlsReachable() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let options = app.buttons["trip.stop"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        reveal(options)
        XCTAssertGreaterThanOrEqual(options.frame.width, 44)
        XCTAssertGreaterThanOrEqual(options.frame.height, 44)
        let follow = app.buttons["trip.follow"]
        reveal(follow)
        XCTAssertTrue(follow.isHittable)
        XCTAssertLessThanOrEqual(follow.frame.maxX, app.frame.maxX)
    }

    private func waitForValue(_ value: String, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
