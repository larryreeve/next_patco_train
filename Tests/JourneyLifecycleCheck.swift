import Foundation

@main
struct JourneyLifecycleCheck {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = JourneyProgressSession(key: "trip", deepLink: "patconext://departure",
            originName: "Origin", destinationName: "Destination", departure: now,
            arrival: now.addingTimeInterval(600), stops: [.init(name: "Destination", arrival: now.addingTimeInterval(600))])
        let restored = try JSONDecoder().decode(JourneyProgressSession.self, from: JSONEncoder().encode(session))
        precondition(restored == session && restored.isActive(at: now))
        precondition(!restored.isActive(at: now.addingTimeInterval(1200)))
        session.completed = true
        precondition(!session.isActive(at: now))
        for reason in ["Background arrival", "Estimated arrival", "App arrival", "User confirmed arrival"] {
            let route = SharedRouteCoordinator.Route(originId: "B", destinationId: "A",
                savedOriginId: "B", savedDestinationId: "A", revision: 2, updatedAt: now, reason: reason, manual: false)
            precondition(route.completesJourney && route.endsJourneyTracking)
        }
        let app = try String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        precondition(!app.contains("if !isViewingToday { locationProvider.endJourneyTracking() }"))
        precondition(app.contains("Active journey route changed while browsing"))
        let detail = try String(contentsOfFile: "NextPATCOTrain/DepartureDetailView.swift", encoding: .utf8)
        let visibility = detail.components(separatedBy: "private var hasTripProgress: Bool")[1]
            .components(separatedBy: "private var detectedStationIds")[0]
        precondition(!visibility.contains("currentTripActivity"))
        let stop = detail.components(separatedBy: "static func stop(departure:")[1]
            .components(separatedBy: "static func start(departure:")[0]
        precondition(!stop.contains(".complete("), "Hiding a Live Activity must not complete the journey")
        print("Journey lifecycle checks passed: persisted session, expiry, completion policy, browsing and progress visibility")
    }
}
