#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct DiagnosticsLayoutCheck {
    static func run() throws {
        let source = try String(contentsOfFile: "NextPATCOTrain/InformationViews.swift", encoding: .utf8)
        let view = source.components(separatedBy: "private struct LocationDiagnosticsView: View {")[1]
            .components(separatedBy: "private enum DiagnosticReportKind")[0]
        XCTAssertTrue(source.contains(".fullScreenCover(isPresented: $showLiveLocationDiagnostics)"))
        XCTAssertTrue(view.contains("Close location diagnostics"))
        XCTAssertTrue(view.contains("ViewThatFits(in: .vertical)"))
        XCTAssertTrue(view.contains("ScrollView { readings }"), "Large text must remain accessible")
        XCTAssertTrue(!view.contains("maxHeight: 290") && !view.contains("minHeight: 220"))
        XCTAssertTrue(view.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        for label in ["Precise Location", "Latitude", "Longitude", "Accuracy radius", "Speed", "Reading time", "Reading quality", "Reading age", "Follow location"] {
            XCTAssertTrue(view.contains("\"\(label)\""), "Missing diagnostic: \(label)")
        }
        XCTAssertTrue(view.contains("monitor.stop()"), "Full-screen dismissal must still stop diagnostic tracking")
        XCTAssertTrue(view.contains("let span = 350.0"), "Accuracy changes must not zoom out from the streets")
        XCTAssertTrue(view.contains("LabeledContent(\"Nearest station\")"))
        let station = Station(id: "test", code: "14", name: "Test Station", latitude: 39.95,
                              longitude: -75.16, zone: "6", url: "")
        let now = Date()
        func location(offset: Double = 0, accuracy: Double = 10, age: Double = 0) -> CLLocation {
            CLLocation(coordinate: .init(latitude: station.latitude + offset / 111195, longitude: station.longitude),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1,
                       timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(LocationDiagnosticFormatting.nearbyStation(location(), stations: [station], now: now) == "Test Station")
        XCTAssertTrue(LocationDiagnosticFormatting.nearbyStation(location(accuracy: 1414), stations: [station], now: now) == "Test Station (estimated)")
        XCTAssertTrue(LocationDiagnosticFormatting.nearbyStation(location(offset: 200), stations: [station], now: now) == "None")
        XCTAssertTrue(LocationDiagnosticFormatting.nearbyStation(location(age: 31), stations: [station], now: now) == "Unavailable")
        XCTAssertTrue(LocationDiagnosticFormatting.nearbyStation(nil, stations: [station], now: now) == "Unavailable")
        print("Diagnostics layout checks passed")
    }
}
