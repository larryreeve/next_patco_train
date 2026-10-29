import Combine
import CoreLocation
import Foundation
import Darwin

struct DiagnosticContext: Codable, Equatable {
    enum Confidence: String, Codable { case precise, estimated, unknown }
    enum Decision: String, Codable { case informational, observed, accepted, pending, rejected, committed }

    var schemaVersion = 1
    let component: String
    let journeyID: String?
    let routeRevision: Int?
    let observationTimestamp: Date?
    let confidence: Confidence
    let decision: Decision
    let rejectionReason: String?

    init(component: String, journeyID: String? = nil, routeRevision: Int? = nil,
         observationTimestamp: Date? = nil, confidence: Confidence = .unknown,
         decision: Decision, rejectionReason: String? = nil) {
        self.component = component
        self.journeyID = journeyID
        self.routeRevision = routeRevision
        self.observationTimestamp = observationTimestamp
        self.confidence = confidence
        self.decision = decision
        self.rejectionReason = rejectionReason
    }

    /// Supply the route being evaluated; never reread it while holding the route lock.
    static func arrival(component: String, route: SharedRouteCoordinator.Route?,
                        location: CLLocation, gate: DestinationArrivalGate?) -> Self {
        .init(component: component, journeyID: route?.journey?.key, routeRevision: route?.revision,
              observationTimestamp: location.timestamp,
              confidence: gate?.confirmed == true ? (gate?.usedNearestStationFallback == true ? .estimated : .precise) : .unknown,
              decision: gate?.confirmed == true ? .accepted : .pending,
              rejectionReason: gate?.confirmed == true ? nil : (gate?.lastDecision ?? "Arrival check unavailable"))
    }
}

enum SharedDiagnosticState {
    enum Surface: String, Codable, CaseIterable {
        case app = "App"
        case homeScreen = "Home Screen widget"
        case lockScreen = "Lock Screen widget"
    }

    struct Snapshot: Codable {
        let routeTitle: String
        let revision: Int?
        let recordedAt: Date
        let nextRequestedAt: Date?
        let locationTimestamp: Date?
        let accuracyMeters: Double?
        let travelEstimateSource: String?
        let appliedSpecialSchedules: [String]?
    }

    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard }

    static func snapshot(for surface: Surface, defaults storage: UserDefaults? = nil) -> Snapshot? {
        guard let data = (storage ?? defaults).data(forKey: key(surface)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func record(_ surface: Surface, origin: Station?, destination: Station?, revision: Int?,
                       at date: Date = Date(), nextRequestedAt: Date? = nil,
                       location: CLLocation? = nil, travelEstimateSource: String? = nil,
                       appliedSpecialSchedules: [String] = [],
                       defaults storage: UserDefaults? = nil) {
        let title = "\(origin?.name ?? "Unknown") to \(destination?.name ?? "Unknown")"
        if surface == .app, let previous = snapshot(for: surface, defaults: storage),
           previous.routeTitle == title, previous.revision == revision,
           previous.appliedSpecialSchedules == appliedSpecialSchedules,
           date.timeIntervalSince(previous.recordedAt) < 30 { return }
        let snapshot = Snapshot(routeTitle: title, revision: revision, recordedAt: date,
                                nextRequestedAt: nextRequestedAt, locationTimestamp: location?.timestamp,
                                accuracyMeters: location?.horizontalAccuracy, travelEstimateSource: travelEstimateSource,
                                appliedSpecialSchedules: appliedSpecialSchedules)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        (storage ?? defaults).set(data, forKey: key(surface))
    }

    private static func key(_ surface: Surface) -> String { "diagnosticSnapshot.\(surface.rawValue)" }
}

enum ArrivalDiagnostics {
    private static let key = "arrivalDiagnosticEvents"
    private static let lock = NSLock()

    static var events: [SharedWidgetDiagnostics.Event] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    static func record(_ title: String, detail: String, context: DiagnosticContext? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var recent = load()
        recent.insert(.init(id: UUID(), date: Date(), title: title, detail: detail,
            context: context ?? .init(component: "app.diagnostics", decision: .informational)), at: 0)
        if let data = try? JSONEncoder().encode(Array(recent.prefix(500))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func load() -> [SharedWidgetDiagnostics.Event] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SharedWidgetDiagnostics.Event].self, from: data)) ?? []
    }
}

enum SharedWidgetDiagnostics {
    struct ReloadRequest: Codable {
        let id: UUID
        let date: Date
        let action: String
        let revision: Int
        let originId: String
        let destinationId: String

        func outcome(revision loadedRevision: Int?, originId loadedOrigin: String?, destinationId loadedDestination: String?) -> String {
            guard let loadedRevision else { return "No matching committed route revision" }
            if loadedRevision > revision { return "Requested revision superseded by a newer route" }
            if loadedRevision == revision && loadedOrigin == originId && loadedDestination == destinationId {
                return "Requested route loaded"
            }
            return "Route mismatch with reload request"
        }
    }

    private static let reloadRequestKey = "widgetDiagnosticReloadRequest"

    static var latestReloadRequest: ReloadRequest? {
        guard let data = defaults.data(forKey: reloadRequestKey) else { return nil }
        return try? JSONDecoder().decode(ReloadRequest.self, from: data)
    }

    static func recordReloadRequest(action: String, deliveryDescription: String = "both widget kinds") {
        guard let route = SharedRouteCoordinator.current() else {
            record("Widget reload requested", detail: "\(action); no committed route; \(deliveryDescription)")
            return
        }
        let request = ReloadRequest(id: UUID(), date: Date(), action: action, revision: route.revision,
                                    originId: route.originId, destinationId: route.destinationId)
        if let data = try? JSONEncoder().encode(request) {
            defaults.set(data, forKey: reloadRequestKey)
        }
        record("Widget reload requested", detail: "Request \(request.id); \(action); expected revision \(route.revision): \(route.originId) to \(route.destinationId); \(deliveryDescription); iOS delivery not confirmed",
               context: .init(component: "widget.reload", journeyID: route.journey?.key,
                    routeRevision: route.revision, decision: .pending))
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        var title: String
        var detail: String
        // Optional for compatibility with diagnostic logs saved before 1.4.
        var context: DiagnosticContext? = nil

        var exportLine: String {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                try container.encode(formatter.string(from: date))
            }
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self), let line = String(data: data, encoding: .utf8) else {
                return "\(date.formatted(.iso8601)) | \(title) | \(detail)"
            }
            return line
        }
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let eventsKey = "widgetDiagnosticEvents"
    private static let limit = 100

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var events: [Event] {
        guard let data = defaults.data(forKey: eventsKey) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    static func record(_ title: String, detail: String, context: DiagnosticContext? = nil) {
        var recent = events
        recent.insert(Event(id: UUID(), date: Date(), title: title, detail: detail,
            context: context ?? .init(component: "widget.diagnostics", decision: .informational)), at: 0)
        save(recent)
    }

    @discardableResult
    static func beginWidgetRun(manual: Bool = false) -> UUID {
        let id = UUID()
        var recent = events
        recent.insert(
            Event(
                id: id,
                date: Date(),
                title: manual ? "Manual location check started" : "Widget timeline started",
                detail: "In progress",
                context: .init(component: "widget.timeline", decision: .pending)
            ),
            at: 0
        )
        save(recent)
        return id
    }

    static func recordLocation(_ outcome: String, duration: TimeInterval, for id: UUID) {
        update(id) { event in
            let durationText = duration < 1 ? "<1 sec" : "\(Int(duration.rounded())) sec"
            event.detail = "\(outcome) in \(durationText)"
        }
    }

    static func finishWidgetRun(
        _ id: UUID,
        manual: Bool = false,
        departureCount: Int? = nil,
        nextReloadAt: Date? = nil,
        nextReloadReason: String? = nil
    ) {
        update(id) { event in
            let elapsed = Int(Date().timeIntervalSince(event.date).rounded())
            event.title = manual ? "Manual location check finished" : "Widget timeline prepared"
            event.context = .init(component: "widget.timeline", decision: .accepted)
            var details = event.detail == "In progress" ? [] : [event.detail]
            if let departureCount {
                details.append("\(departureCount) upcoming departures")
            }
            details.append("Completed in \(elapsed) sec")
            if let nextReloadAt {
                details.append("Next requested \(nextReloadAt.formatted(date: .omitted, time: .shortened))")
            }
            if let nextReloadReason {
                details.append(nextReloadReason)
            }
            event.detail = details.joined(separator: " · ")
        }
    }

    private static func update(_ id: UUID, change: (inout Event) -> Void) {
        var recent = events
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        change(&recent[index])
        save(recent)
    }

    private static func save(_ recent: [Event]) {
        var appCount = 0
        var widgetCount = 0
        let retained = recent.filter { event in
            if event.title.hasPrefix("App ") {
                appCount += 1
                return appCount <= limit
            }
            widgetCount += 1
            return widgetCount <= limit
        }
        if let data = try? JSONEncoder().encode(retained) {
            defaults.set(data, forKey: eventsKey)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: eventsKey)
        defaults.removeObject(forKey: reloadRequestKey)
    }
}
