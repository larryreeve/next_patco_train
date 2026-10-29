import Foundation

/// Lifecycle decisions shared by the app, widgets and Live Activity adapters.
/// All mutations run inside SharedRouteCoordinator's cross-process transaction.
enum JourneyCoordinator {
    enum Event { case arrive, cancel, expire }

    static func transition(_ session: inout JourneyProgressSession, event: Event) {
        guard session.state == .tracking else { return }
        switch event {
        case .arrive: session.setState(.arrived)
        case .cancel: session.setState(.cancelled)
        case .expire: session.setState(.expired)
        }
    }

    static func start(_ session: JourneyProgressSession, route: inout SharedRouteCoordinator.Route?,
                      expectedRevision: Int, now: Date, explicitRestart: Bool) {
        guard let old = route, old.revision == expectedRevision,
              let url = URL(string: session.deepLink), let link = DepartureDeepLink(url: url),
              (link.originId == old.originId || link.originId == old.temporaryRoute?.originId),
              link.destinationId == old.destinationId, session.isActive(at: now),
              old.journey?.key != session.key else { return }
        guard old.journey?.deepLink != session.deepLink || old.journey?.isActive(at: now) == true
                || (explicitRestart && old.journey?.state == .cancelled) else { return }
        route?.journey = session
        if old.journey?.deepLink != session.deepLink { route?.journeyProgress = TripLocationProgress() }
    }

    static func cancel(key: String, route: inout SharedRouteCoordinator.Route?) {
        guard route?.journey?.key == key else { return }
        if var session = route?.journey {
            transition(&session, event: .cancel)
            route?.journey = session
        }
    }

    static func restore(route: inout SharedRouteCoordinator.Route?, now: Date) {
        guard var session = route?.journey,
              ScheduledTripExpiration.hasExpired(arrivalDate: session.arrival, now: now) else { return }
        transition(&session, event: .expire)
        route?.journey = session
    }

    static func reconcile(previous: SharedRouteCoordinator.Route?, next: inout SharedRouteCoordinator.Route?) {
        guard let old = previous, let updated = next, old.revision != updated.revision else { return }
        next?.journey = old.journey
        next?.journeyProgress = old.journeyProgress
        guard var session = old.journey else { return }
        if updated.completesJourney {
            transition(&session, event: .arrive)
        } else if updated.event.endsTracking || updated.destinationId != old.destinationId
            || (!updated.event.isTemporary && (updated.savedOriginId != old.savedOriginId
                || updated.savedDestinationId != old.savedDestinationId)) {
            transition(&session, event: .cancel)
        }
        next?.journey = session
    }
}

struct JourneyProgressSession: Codable, Equatable {
    enum State: String, Codable { case tracking, arrived, cancelled, expired }
    enum Termination: String, Codable { case arrived, cancelled, expired }
    struct Stop: Codable, Equatable {
        let name: String
        let arrival: Date
    }
    let key: String
    let deepLink: String
    let originName: String
    let destinationName: String
    let departure: Date
    let arrival: Date
    let stops: [Stop]
    private(set) var state: State = .tracking

    // Read-only compatibility projections; contradictory flags can no longer be written.
    var completed: Bool { state == .arrived }
    var termination: Termination? { Termination(rawValue: state.rawValue) }
    fileprivate mutating func setState(_ value: State) { state = value }

    init(key: String, deepLink: String, originName: String, destinationName: String,
         departure: Date, arrival: Date, stops: [Stop]) {
        self.key = key; self.deepLink = deepLink
        self.originName = originName; self.destinationName = destinationName
        self.departure = departure; self.arrival = arrival; self.stops = stops
    }

    func isActive(at now: Date = Date()) -> Bool {
        state == .tracking && !ScheduledTripExpiration.hasExpired(arrivalDate: arrival, now: now)
    }

    func suppressesAutomaticTracking(originId: String?, destinationId: String?, at now: Date = Date()) -> Bool {
        guard state == .cancelled, !ScheduledTripExpiration.hasExpired(arrivalDate: arrival, now: now),
              let url = URL(string: deepLink), let link = DepartureDeepLink(url: url) else { return false }
        return link.originId == originId && link.destinationId == destinationId
    }

    private enum CodingKeys: String, CodingKey {
        case key, deepLink, originName, destinationName, departure, arrival, stops, state, completed, termination
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        deepLink = try values.decode(String.self, forKey: .deepLink)
        originName = try values.decode(String.self, forKey: .originName)
        destinationName = try values.decode(String.self, forKey: .destinationName)
        departure = try values.decode(Date.self, forKey: .departure)
        arrival = try values.decode(Date.self, forKey: .arrival)
        stops = try values.decode([Stop].self, forKey: .stops)
        if let saved = try values.decodeIfPresent(State.self, forKey: .state) {
            state = saved
        } else if try values.decodeIfPresent(Bool.self, forKey: .completed) == true {
            state = .arrived
        } else if let ended = try values.decodeIfPresent(Termination.self, forKey: .termination) {
            state = State(rawValue: ended.rawValue)!
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(deepLink, forKey: .deepLink)
        try values.encode(originName, forKey: .originName)
        try values.encode(destinationName, forKey: .destinationName)
        try values.encode(departure, forKey: .departure)
        try values.encode(arrival, forKey: .arrival)
        try values.encode(stops, forKey: .stops)
        try values.encode(state, forKey: .state)
        // Older app/widget binaries may still read the shared file during an upgrade.
        try values.encode(completed, forKey: .completed)
        try values.encodeIfPresent(termination, forKey: .termination)
    }
}
