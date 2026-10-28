import Foundation

@main
struct EarlierDeparturesCheck {
    static func main() throws {
        func count(_ statuses: [Bool?], reliable: Bool = true) -> Int {
            EarlierDeparturesPolicy.collapsibleCount(unreachable: statuses, hasReliableEstimate: reliable)
        }
        precondition(count([true, true, false, false]) == 2)
        precondition(count([true, false]) == 1, "Tight and comfortable trains stay visible")
        precondition(count([true, true, false], reliable: false) == 0, "Unavailable, stale or fallback estimates must not hide trains")
        precondition(count([nil, true, false]) == 0)
        precondition(count([true, nil, true, false]) == 1, "Unknown guidance must remain visible")
        precondition(count([false, true, false]) == 0, "Only the leading unreachable group collapses")
        precondition(count([true, true]) == 0, "Keep all trains visible when none is reachable")
        precondition(count([true]) == 0)
        precondition(count([]) == 0)
        precondition(count([nil, nil]) == 0)

        let now = Date(timeIntervalSince1970: 1_791_460_000)
        let cachedRows: [(date: Date, unreachable: Bool?)] = [
            (now.addingTimeInterval(-1), nil),
            (now.addingTimeInterval(9 * 60), true),
            (now.addingTimeInterval(19 * 60), true),
            (now.addingTimeInterval(29 * 60), false),
            (now.addingTimeInterval(43 * 60), false)
        ]
        let visibleRows = cachedRows.filter {
            EarlierDeparturesPolicy.shouldDisplay(departureDate: $0.date, isViewingToday: true, now: now)
        }
        precondition(visibleRows.count == 4)
        precondition(count(visibleRows.map(\.unreachable)) == 2,
                     "A departed row with unknown guidance must not block the missed-train group")
        precondition(visibleRows[2].date == now.addingTimeInterval(29 * 60), "The tight train remains visible")
        precondition(EarlierDeparturesPolicy.shouldDisplay(departureDate: now, isViewingToday: true, now: now))
        precondition(!EarlierDeparturesPolicy.shouldDisplay(departureDate: now, isViewingToday: true,
                                                           now: now.addingTimeInterval(0.001)))
        precondition(EarlierDeparturesPolicy.shouldDisplay(departureDate: now.addingTimeInterval(-86400),
                                                          isViewingToday: false, now: now))
        let app = try String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        let rows = app.components(separatedBy: "private func departureRows(at now: Date)")[1]
            .components(separatedBy: "private func hasReliableDepartureEstimate")[0]
        precondition(rows.contains("let departures = visibleDepartures(at: now)"))
        precondition(rows.contains("hasReliableDepartureEstimate(at: now)"))
        precondition(rows.contains("departures.map { listCatchStatus(for: $0, at: now) }"))
        precondition(rows.contains("ForEach(departures.indices"))
        let reliability = app.components(separatedBy: "private func hasReliableDepartureEstimate")[1]
            .components(separatedBy: "private var laterDeparturesDivider")[0]
        precondition(reliability.range(of: "if let sharedTrip")!.lowerBound
            < reliability.range(of: "guard let mode = currentReachabilityMode(at: now)")!.lowerBound)
        let list = app.components(separatedBy: "private var departureList:")[1]
            .components(separatedBy: "private func departureRows")[0]
        precondition(list.contains("departuresHeader(at: now)") && list.contains("departureRows(at: now)"))
        let mode = app.components(separatedBy: "private func currentReachabilityMode(at now: Date)")[1]
            .components(separatedBy: "private var sheetContent")[0]
        precondition(mode.contains("let departures = visibleDepartures(at: now)"))

        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let start = PATCOClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let base = store.departures(from: origin, to: destination, after: start, limit: 1).first!
        let departures = [-1.0, 540, 1140, 1740, 2580].map { offset in
            Departure(trip: base.trip, origin: origin, destination: destination,
                originTime: base.originTime, destinationTime: base.destinationTime, serviceDate: now,
                departureDate: now.addingTimeInterval(offset), arrivalDate: now.addingTimeInterval(offset + 1440),
                routeSequenceIndex: 0, isSpecialSchedule: false, isRemovedBySpecialSchedule: false, scheduleAdjustment: nil)
        }
        let trip = SharedTripState.Snapshot(schema: 1, routeRevision: 1, origin: origin, destination: destination,
            preparedAt: now.addingTimeInterval(-10), departures: departures, scheduleVersion: nil,
            scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
            guidance: .init(location: .init(latitude: origin.latitude + 0.01, longitude: origin.longitude,
                horizontalAccuracy: 5, timestamp: now), mode: .driving, travelMinutes: 25,
                estimateSource: "Maps estimate", estimateFetchedAt: now), lastBroadcastAt: now)
        for elapsed in [0.0, 1, 29] {
            let renderTime = now.addingTimeInterval(elapsed)
            let visible = EarlierDeparturesPolicy.visibleDepartures(departures, isViewingToday: true, now: renderTime)
            precondition(trip.catchResult(for: departures[0], at: renderTime) == nil)
            let results = visible.map { trip.catchResult(for: $0, at: renderTime) }
            precondition(results.first!!.mode == .driving, "Header mode survives the expired cached first departure")
            precondition(results[2]?.status == .tight && results[3]?.status == .comfortable)
            precondition(count(results.map { $0.map { !$0.isMakeable } },
                reliable: trip.guidance!.hasFreshMapsEstimate(at: renderTime)) == 2,
                "The complete filtering, guidance and grouping pipeline must collapse both missed trains")
        }
        func guidance(age: TimeInterval = 0, locationAge: TimeInterval = 0,
                      accuracy: Double = 15, source: String = "Maps estimate") -> SharedTripState.Guidance {
            SharedTripState.Guidance(
                location: .init(latitude: 39.86, longitude: -75.01,
                                horizontalAccuracy: accuracy, timestamp: now.addingTimeInterval(-locationAge)),
                mode: .driving, travelMinutes: 21, estimateSource: source,
                estimateFetchedAt: now.addingTimeInterval(-age))
        }
        let today = guidance(age: 30)
        precondition(today.hasFreshMapsEstimate(at: now))
        precondition(count([true, true, false], reliable: today.hasFreshMapsEstimate(at: now)) == 2,
                     "Returning to today restores grouping from the same guidance used for timing badges")
        precondition(count([true, true, false], reliable: false) == 0, "Other dates do not collapse departures")
        precondition(!guidance(age: 300).hasFreshMapsEstimate(at: now))
        precondition(!guidance(age: -1).hasFreshMapsEstimate(at: now))
        precondition(!guidance(locationAge: 181).hasFreshMapsEstimate(at: now))
        precondition(!guidance(accuracy: 151).hasFreshMapsEstimate(at: now))
        precondition(!guidance(source: "Distance-based fallback").hasFreshMapsEstimate(at: now))

        let encoded = try JSONEncoder().encode(today)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "estimateFetchedAt")
        let decoded = try JSONDecoder().decode(SharedTripState.Guidance.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!decoded.hasFreshMapsEstimate(at: now), "Legacy snapshots decode but cannot hide trains without freshness evidence")
        print("Earlier departures checks passed: date return, snapshot freshness, legacy decoding and conservative grouping")
    }
}
