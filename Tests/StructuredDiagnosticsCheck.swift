#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct StructuredDiagnosticsCheck {
    static func run() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)
        let location = CLLocation(coordinate: .init(latitude: 39.9, longitude: -75), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: 0, timestamp: date)
        let context = DiagnosticContext(component: "test.arrival", journeyID: "trip-123", routeRevision: 42,
            observationTimestamp: date, confidence: .estimated, decision: .accepted)
        let event = SharedWidgetDiagnostics.Event(id: UUID(), date: date.addingTimeInterval(3),
            title: "Estimated arrival", detail: "Repeated readings\nwith distinct timestamps", context: context)
        let decoded = try JSONDecoder().decode(SharedWidgetDiagnostics.Event.self, from: JSONEncoder().encode(event))
        XCTAssertTrue(decoded.context == context)
        XCTAssertTrue(decoded.date != decoded.context?.observationTimestamp, "Observation time is not callback or export time")
        XCTAssertTrue(!event.exportLine.contains("\n"), "One JSON line per event, including multiline details")
        let exportDecoder = JSONDecoder()
        exportDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
            }
            return date
        }
        let exported = try exportDecoder.decode(SharedWidgetDiagnostics.Event.self, from: Data(event.exportLine.utf8))
        XCTAssertTrue(exported.context == context && exported.detail == event.detail)
        XCTAssertTrue(event.exportLine.contains(".125Z"), "Export must retain subsecond observations")
        XCTAssertTrue(!event.exportLine.contains("latitude") && !event.exportLine.contains("longitude"))

        let oldEvent = SharedWidgetDiagnostics.Event(id: UUID(), date: date, title: "Old event", detail: "Still readable")
        let legacy = try JSONDecoder().decode(SharedWidgetDiagnostics.Event.self, from: JSONEncoder().encode(oldEvent))
        XCTAssertTrue(legacy.context == nil && legacy.detail == oldEvent.detail)
        XCTAssertTrue(legacy.exportLine.contains("Still readable"))

        var gate = DestinationArrivalGate()
        let pending = DiagnosticContext.arrival(component: "app.arrival", route: nil, location: location, gate: gate)
        XCTAssertTrue(pending.routeRevision == nil && pending.journeyID == nil)
        XCTAssertTrue(pending.confidence == .unknown && pending.decision == .pending && pending.rejectionReason != nil)
        _ = gate.accepts(destinationId: "A", station: location, location: location, now: date)
        let later = CLLocation(coordinate: location.coordinate, altitude: 0, horizontalAccuracy: 5,
            verticalAccuracy: 1, course: -1, speed: 0, timestamp: date.addingTimeInterval(10))
        _ = gate.accepts(destinationId: "A", station: location, location: later, now: later.timestamp)
        XCTAssertTrue(gate.confirmed)
        let accepted = DiagnosticContext.arrival(component: "shared.arrival", route: nil, location: later, gate: gate)
        XCTAssertTrue(accepted.decision == .accepted && accepted.confidence == .precise && accepted.rejectionReason == nil)
        var route = SharedRouteCoordinator.Route(originId: "O", destinationId: "A", savedOriginId: "O", savedDestinationId: "A",
            revision: 42, updatedAt: date, lastLocationAt: nil, reason: "test", manual: false)
        route.journey = JourneyProgressSession(key: "trip-123", deepLink: "", originName: "O", destinationName: "A",
            departure: date, arrival: date.addingTimeInterval(600), stops: [])
        let correlated = DiagnosticContext.arrival(component: "app.arrival", route: route, location: later, gate: gate)
        XCTAssertTrue(correlated.journeyID == "trip-123" && correlated.routeRevision == 42)
        print("Structured diagnostics checks passed: legacy decoding, typed context, JSON-lines export, timestamps, confidence and privacy")
    }
}
