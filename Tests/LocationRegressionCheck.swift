import Foundation
import CoreLocation

@main
struct LocationRegressionCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
            Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
        }
        func fix(_ latitude: Double, _ seconds: Double, accuracy: Double = 20) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -75.16),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: 0,
                       timestamp: now.addingTimeInterval(seconds))
        }
        var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", now: now, directory: root)!
        func check(_ location: CLLocation?, at seconds: Double) -> DestinationArrivalGate? {
            SharedRouteCoordinator.checkArrival(expectedRevision: route.revision, location: location,
                stations: stations, now: now.addingTimeInterval(seconds), directory: root)
        }
        _ = check(fix(39.98, 1), at: 1)
        _ = check(fix(39.965, 2), at: 2)
        precondition(check(fix(39.9503, 3, accuracy: 1414), at: 3)?.confirmed == false)
        // An out-of-order or stale contradictory fix must not discard newer evidence.
        _ = check(fix(39.965, 2), at: 4)
        _ = check(fix(39.965, -50), at: 4)
        precondition(check(fix(39.9556, 14, accuracy: 52), at: 14)?.confirmed == false)
        // A fresh, accurate fix at another station does discard it, including across relaunch.
        _ = check(fix(39.965, 15), at: 15)
        route = SharedRouteCoordinator.current(directory: root)!
        precondition(check(fix(39.9556, 26, accuracy: 52), at: 26)?.confirmed == false)
        precondition(check(fix(39.9503, 27, accuracy: 1414), at: 27)?.confirmed == false)
        precondition(check(fix(39.9556, 38, accuracy: 52), at: 38)?.confirmed == false)

        // App arrival processing must reject old callbacks before any observer can clear the dwell.
        for (name, older) in [("outside-destination", fix(39.965, 5)), ("invalid-coordinate", fix(91, 5))] {
            let directory = root.appendingPathComponent(name)
            let selected = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                now: now, directory: directory)!
            let first = SharedRouteCoordinator.checkArrival(expectedRevision: selected.revision,
                location: fix(39.95, 10), stations: stations, now: now.addingTimeInterval(10), directory: directory)!
            precondition(!first.confirmed && first.hasStopEvidence)
            let rejected = SharedRouteCoordinator.checkArrival(expectedRevision: selected.revision,
                location: older, stations: stations, now: now.addingTimeInterval(11), directory: directory)!
            precondition(!rejected.confirmed && rejected.hasStopEvidence,
                "Older \(name) callback must preserve the newer destination stop")
            precondition(rejected.lastDecision == "Out-of-order location reading")
            precondition(SharedRouteCoordinator.current(directory: directory)?.arrivalGate == rejected,
                "Preserved stop evidence must survive a persisted route reload")
            let confirmed = SharedRouteCoordinator.checkArrival(expectedRevision: selected.revision,
                location: fix(39.95, 20), stations: stations, now: now.addingTimeInterval(20), directory: directory)!
            precondition(confirmed.confirmed, "Arrival must confirm at timestamp 20 after older \(name)")
            precondition(SharedRouteCoordinator.current(directory: directory)?.revision == selected.revision)
        }
        for observer in ["journey", "departure", "invalidation"] {
            for timestamp in [5.0, 10.0] {
                var gate = DestinationArrivalGate()
                precondition(!gate.accepts(destinationId: "B", station: stations[2].location,
                    location: fix(39.95, 10), routeSelectedAt: now, now: now.addingTimeInterval(10)))
                let newerEvidence = gate
                if observer == "journey" {
                    gate.observeJourney(origin: stations[0].location, destination: stations[2].location,
                        location: fix(39.98, timestamp), selectedAt: now, now: now.addingTimeInterval(11))
                } else if observer == "departure" {
                    gate.observeDeparture(from: stations[2].location,
                        location: fix(39.965, timestamp), now: now.addingTimeInterval(11))
                } else {
                    gate.invalidateDestinationEvidence(location: fix(39.965, timestamp))
                }
                precondition(gate == newerEvidence, "Direct \(observer) observation must ignore duplicate and older timestamps")
                precondition(gate.accepts(destinationId: "B", station: stations[2].location,
                    location: fix(39.95, 20), routeSelectedAt: now, now: now.addingTimeInterval(20)))
            }
        }

        // Either widget or app may replay a cached fix after it has aged out of arrival freshness.
        for replaySource in ["app", "widget"] {
            for confirmationSource in ["app", "widget"] {
                let directory = root.appendingPathComponent("replay-\(replaySource)-\(confirmationSource)")
                let selected = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                    now: now, directory: directory)!
                let first = fix(39.95, 100)
                let initialGate = SharedRouteCoordinator.checkArrival(expectedRevision: selected.revision,
                    location: first, stations: stations, now: first.timestamp, directory: directory)!
                precondition(initialGate.hasStopEvidence && !initialGate.confirmed)
                for receivedAt in [101.0, 116.0] {
                    let received = now.addingTimeInterval(receivedAt)
                    if replaySource == "app" {
                        _ = SharedRouteCoordinator.checkArrival(expectedRevision: selected.revision,
                            location: first, stations: stations, now: received, directory: directory)
                    } else {
                        _ = SharedRouteCoordinator.resolveWidgetRoute(location: first, stations: stations,
                            now: received, directory: directory)
                    }
                    let persisted = SharedRouteCoordinator.current(directory: directory)!
                    precondition(persisted.revision == selected.revision)
                    precondition(persisted.arrivalGate?.hasStopEvidence == true && persisted.arrivalGate?.confirmed == false,
                        "Fresh and stale duplicates must neither erase nor advance arrival evidence")
                    precondition(persisted.arrivalGate?.lastDecision == "Duplicate location reading")
                }
                let second = fix(39.95, 110)
                let received = now.addingTimeInterval(117)
                if confirmationSource == "app" {
                    let gate = SharedRouteCoordinator.checkArrival(expectedRevision: selected.revision,
                        location: second, stations: stations, now: received, directory: directory)!
                    precondition(gate.confirmed, "The next distinct fresh fix must retain the pre-replay dwell")
                } else {
                    let arrived = SharedRouteCoordinator.resolveWidgetRoute(location: second, stations: stations,
                        now: received, directory: directory)!
                    precondition(arrived.revision == selected.revision + 1 && arrived.originId == "B" && arrived.destinationId == "A",
                        "Widget arrival must retain dwell through cached replays and reverse exactly once")
                    precondition(SharedRouteCoordinator.resolveWidgetRoute(location: second, stations: stations,
                        now: received, directory: directory)?.revision == arrived.revision)
                }
            }
        }
        for disturbance in ["inaccurate", "moving", "outside", "stale", "gap"] {
            var gate = DestinationArrivalGate()
            precondition(!gate.accepts(destinationId: "B", station: stations[2].location,
                location: fix(39.95, 100), now: now.addingTimeInterval(100)))
            precondition(!gate.accepts(destinationId: "B", station: stations[2].location,
                location: fix(39.95, 100), now: now.addingTimeInterval(116)))
            precondition(gate.hasStopEvidence)
            let nextTimestamp = disturbance == "gap" ? 120.0 : 110.0
            if disturbance != "gap" {
                let bad = CLLocation(coordinate: .init(latitude: disturbance == "outside" ? 39.965 : 39.95, longitude: -75.16),
                    altitude: 0, horizontalAccuracy: disturbance == "inaccurate" ? 200 : 20, verticalAccuracy: 1,
                    course: 0, speed: disturbance == "moving" ? 5 : 0, timestamp: now.addingTimeInterval(101))
                precondition(!gate.accepts(destinationId: "B", station: stations[2].location, location: bad,
                    now: now.addingTimeInterval(disturbance == "stale" ? 117 : 116)))
                precondition(!gate.hasStopEvidence, "A distinct new \(disturbance) reading must still reset arrival evidence")
            }
            let entered = gate.accepts(destinationId: "B", station: stations[2].location,
                location: fix(39.95, nextTimestamp), now: now.addingTimeInterval(max(117, nextTimestamp)))
            precondition(entered == (disturbance == "outside"),
                "Only a genuine boundary re-entry can confirm without a new stop window")
            precondition(gate.accepts(destinationId: "B", station: stations[2].location,
                location: fix(39.95, nextTimestamp + 10), now: now.addingTimeInterval(nextTimestamp + 10)))
        }

        // Every endpoint on temporary outbound and return routes produces a distinct route.
        for temporaryDestination in ["A", "B"] {
            for endpoint in ["A", "B"] {
                route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                    now: now.addingTimeInterval(40), directory: root)!
                route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
                    originId: "C", destinationId: temporaryDestination, stations: stations,
                    now: now.addingTimeInterval(41), directory: root)!
                let location = fix(endpoint == "A" ? 39.98 : 39.95, 42)
                let before = route.revision
                route = SharedRouteCoordinator.selectNearestStation(expectedRevision: before,
                    location: location, stations: stations, now: location.timestamp, directory: root)!
                precondition(route.revision == before + 1 && route.originId == endpoint)
                precondition(route.destinationId == (endpoint == "A" ? "B" : "A"))
                precondition(route.temporaryRoute == nil && route.manual)
            }
        }

        // Test real neighboring stations, not only widely separated synthetic fixtures.
        let feed = try JSONDecoder().decode(PATCOFeed.self,
            from: Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let west = feed.stops.first { $0.name.contains("15/16") }!
        let east = feed.stops.first { $0.name.contains("12/13") }!
        for fraction in [0.48, 0.5, 0.52] {
            let location = CLLocation(coordinate: CLLocationCoordinate2D(
                latitude: west.latitude + fraction * (east.latitude - west.latitude),
                longitude: west.longitude + fraction * (east.longitude - west.longitude)),
                altitude: 0, horizontalAccuracy: 20, verticalAccuracy: 1, timestamp: now)
            precondition(LocationGuidancePolicy.detectedStation(location, stations: feed.stops, now: now) == nil)
            precondition(LocationGuidancePolicy.nearestUnambiguousStation(location, stations: feed.stops, now: now) == nil)
        }
        for station in [west, east] {
            let location = CLLocation(coordinate: station.coordinate, altitude: 0,
                horizontalAccuracy: 20, verticalAccuracy: 1, timestamp: now)
            precondition(LocationGuidancePolicy.detectedStation(location, stations: feed.stops, now: now)?.id == station.id)
        }

        // Compass waits for a post-request callback; timeout and bad callbacks leave state untouched.
        route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: now.addingTimeInterval(50), directory: root)!
        let beforeRequest = route
        let requestedAt = now.addingTimeInterval(80)
        for reading in [nil, fix(39.95, 51), fix(39.95, 79.9), fix(39.95, 82, accuracy: 151), fix(39.95, 90)] as [CLLocation?] {
            precondition(LocationInteractionPolicy.freshSelectionLocation(reading, requestedAt: requestedAt,
                now: now.addingTimeInterval(88)) == nil)
        }
        precondition(SharedRouteCoordinator.current(directory: root) == beforeRequest)
        let fresh = LocationInteractionPolicy.freshSelectionLocation(fix(39.95, 83),
            requestedAt: requestedAt, now: now.addingTimeInterval(83))!
        route = SharedRouteCoordinator.selectNearestStation(expectedRevision: route.revision,
            location: fresh, stations: stations, now: fresh.timestamp, directory: root)!
        precondition(route.originId == "B" && route.destinationId == "A")

        // Stop -> relaunch -> location loss -> departure -> original route -> destination arrival.
        route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: now.addingTimeInterval(100), directory: root)!
        route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision,
            originId: "C", destinationId: "B", stations: stations, automatic: true,
            now: now.addingTimeInterval(101), directory: root)!
        route = SharedRouteCoordinator.current(directory: root)!
        let atStop = route
        precondition(check(nil, at: 102) == nil)
        for reading in [nil, fix(39.96, 70), fix(39.96, 105, accuracy: 1000), fix(39.965, 105)] as [CLLocation?] {
            precondition(SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                departureLocation: reading, requireDeparture: true, stations: stations,
                now: now.addingTimeInterval(105), directory: root) == atStop)
        }
        route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
            departureLocation: fix(39.96, 106), requireDeparture: true, stations: stations,
            now: now.addingTimeInterval(106), directory: root)!
        precondition(route.originId == "A" && route.destinationId == "B" && route.manual)
        precondition(route.temporaryRoute == nil)
        precondition(check(fix(39.95, 110), at: 110)?.confirmed == false)
        precondition(check(fix(39.95, 120), at: 120)?.confirmed == true)
        let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: "B", currentOrigin: route.originId,
            savedOrigin: route.savedOriginId, savedDestination: route.savedDestinationId)
        route = SharedRouteCoordinator.commit(originId: "B", destinationId: returnId, expectedRevision: route.revision,
            arrival: true, observationAt: now.addingTimeInterval(120), now: now.addingTimeInterval(120), directory: root)!
        precondition(route.originId == "B" && route.destinationId == "A")

        // Permissions and scene transitions never authorize idle background tracking.
        for status in [CLAuthorizationStatus.denied, .restricted, .notDetermined] {
            for foreground in [false, true] {
                precondition(!LocationInteractionPolicy.shouldRunUpdates(authorization: status,
                    isForeground: foreground, trackingDeadline: now.addingTimeInterval(600), now: now))
            }
        }
        for status in [CLAuthorizationStatus(rawValue: 4)!, .authorizedAlways] {
            precondition(LocationInteractionPolicy.shouldRunUpdates(authorization: status,
                isForeground: true, trackingDeadline: nil, now: now))
            for deadline in [nil, now, now.addingTimeInterval(-1), now.addingTimeInterval(7201)] as [Date?] {
                precondition(!LocationInteractionPolicy.shouldRunUpdates(authorization: status,
                    isForeground: false, trackingDeadline: deadline, now: now))
            }
            precondition(LocationInteractionPolicy.shouldRunUpdates(authorization: status,
                isForeground: false, trackingDeadline: now.addingTimeInterval(600), now: now))
        }
        route = SharedRouteCoordinator.reverse(expectedRevision: route.revision, now: now.addingTimeInterval(120), directory: root)!
        let manual = route
        for _ in 0..<3 {
            precondition(check(nil, at: 121) == nil)
            route = SharedRouteCoordinator.current(directory: root)!
            precondition(SharedRouteCoordinator.commit(originId: "B", destinationId: "A",
                expectedRevision: route.revision, observationAt: now.addingTimeInterval(122), directory: root) == manual)
        }
        print("Location regression checks passed: cached arrival replays, out-of-order app/gate evidence, contradictory evidence, compass, station ambiguity, relaunch, permissions and lifecycle")
    }
}
