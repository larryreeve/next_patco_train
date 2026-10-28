import Foundation
import CoreLocation

@main
struct DiagnosticsLayoutCheck {
    static func main() throws {
        let source = try String(contentsOfFile: "NextPATCOTrain/InformationViews.swift", encoding: .utf8)
        let view = source.components(separatedBy: "private struct LocationDiagnosticsView: View {")[1]
            .components(separatedBy: "private enum DiagnosticReportKind")[0]
        precondition(source.contains(".fullScreenCover(isPresented: $showLiveLocationDiagnostics)"))
        precondition(view.contains("Close location diagnostics"))
        precondition(view.contains("ViewThatFits(in: .vertical)"))
        precondition(view.contains("ScrollView { readings }"), "Large text must remain accessible")
        precondition(!view.contains("maxHeight: 290") && !view.contains("minHeight: 220"))
        precondition(view.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        for label in ["Precise Location", "Latitude", "Longitude", "Accuracy radius", "Speed", "Reading time", "Reading quality", "Reading age", "Follow location"] {
            precondition(view.contains("\"\(label)\""), "Missing diagnostic: \(label)")
        }
        precondition(view.contains("monitor.stop()"), "Full-screen dismissal must still stop diagnostic tracking")
        precondition(view.contains("let span = 350.0"), "Accuracy changes must not zoom out from the streets")
        precondition(view.contains("LabeledContent(\"Nearest station\")"))
        let station = Station(id: "test", code: "14", name: "Test Station", latitude: 39.95,
                              longitude: -75.16, zone: "6", url: "")
        let now = Date()
        func location(offset: Double = 0, accuracy: Double = 10, age: Double = 0) -> CLLocation {
            CLLocation(coordinate: .init(latitude: station.latitude + offset / 111195, longitude: station.longitude),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1,
                       timestamp: now.addingTimeInterval(-age))
        }
        precondition(LocationDiagnosticFormatting.nearbyStation(location(), stations: [station], now: now) == "Test Station")
        precondition(LocationDiagnosticFormatting.nearbyStation(location(accuracy: 1414), stations: [station], now: now) == "Test Station (estimated)")
        precondition(LocationDiagnosticFormatting.nearbyStation(location(offset: 200), stations: [station], now: now) == "None")
        precondition(LocationDiagnosticFormatting.nearbyStation(location(age: 31), stations: [station], now: now) == "Unavailable")
        precondition(LocationDiagnosticFormatting.nearbyStation(nil, stations: [station], now: now) == "Unavailable")
        print("Diagnostics layout checks passed")
    }
}
