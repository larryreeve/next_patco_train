import Foundation

// Supplemental legacy lint only. Behavioral and UI checks do not use this helper.
enum SourceInspection {
    static func home() throws -> String {
        try ["HomeRouteController", "HomeReachabilityPresentation", "HomeScreenModel",
             "HomeScheduleController", "ContentView", "HomeScreenContent", "HomeDeparturesSection"]
            .map { try String(contentsOfFile: "NextPATCOTrain/\($0).swift", encoding: .utf8) }
            .joined(separator: "\n")
    }

    static func widget() throws -> String {
        try ["WidgetTimelineProvider", "WidgetTravelTimeEstimator", "WidgetLocationProvider",
             "WidgetRouteState", "WidgetReachability", "WidgetActions", "HomeWidgetView",
             "LockScreenWidget", "TripLiveActivityWidget", "WidgetComponents", "NextPATCOTrainWidget"]
            .map { try String(contentsOfFile: "NextPATCOTrainWidget/\($0).swift", encoding: .utf8) }
            .joined(separator: "\n")
    }

    static func models() throws -> String {
        let files = try FileManager.default.contentsOfDirectory(atPath: "NextPATCOTrain/Core")
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try (["NextPATCOTrain/PATCOModels.swift"] + files.map { "NextPATCOTrain/Core/\($0)" })
            .map { try String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}
