import Foundation
import CoreLocation

@main
struct SharedRouteCheck {
    static func main() throws {
        if CommandLine.arguments.count == 4 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            SharedRouteCoordinator.commit(originId: CommandLine.arguments[2], destinationId: "B",
                                          expectedRevision: 1, directory: directory)
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let initial = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                                    now: now, directory: directory)!
        precondition(initial.revision == 1)
        // Oct 8: an automatically reversed return route must survive app refresh/reopening,
        // even when local endpoints or cached journey direction still describe the outbound trip.
        let appRefreshDirectory = directory.appendingPathComponent("app-refresh-direction")
        let bootstrapped = SharedRouteCoordinator.routeForApp(defaultOriginId: "A", defaultDestinationId: "B",
            now: now, directory: appRefreshDirectory)!
        precondition(bootstrapped.revision == 1 && !bootstrapped.manual)
        let returning = SharedRouteCoordinator.commit(originId: "B", destinationId: "A",
            expectedRevision: bootstrapped.revision, arrival: true,
            now: now.addingTimeInterval(10), directory: appRefreshDirectory)!
        precondition(!returning.manual && returning.revision == 2)
        for _ in 0..<20 {
            let refreshed = SharedRouteCoordinator.routeForApp(defaultOriginId: "A", defaultDestinationId: "B",
                now: now.addingTimeInterval(600), directory: appRefreshDirectory)!
            precondition(refreshed == returning, "App refresh cannot rewrite a return route or reset its arrival evidence")
        }
        let manuallyRestored = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: now.addingTimeInterval(601), directory: appRefreshDirectory)!
        precondition(SharedRouteCoordinator.routeForApp(defaultOriginId: "B", defaultDestinationId: "A",
            directory: appRefreshDirectory) == manuallyRestored)
        let reverseDirectory = directory.appendingPathComponent("manual-reversal")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                         now: now, directory: reverseDirectory)
        let reversed = SharedRouteCoordinator.reverse(expectedRevision: 1, directory: reverseDirectory)!
        precondition(reversed.originId == "B" && reversed.destinationId == "A" && reversed.manual)
        precondition(reversed.savedOriginId == "B" && reversed.savedDestinationId == "A")
        let staleReverse = SharedRouteCoordinator.reverse(expectedRevision: 1, directory: reverseDirectory)!
        precondition(staleReverse == reversed)
        let stations = [
            Station(id: "A", code: "A", name: "Origin", latitude: 39.94, longitude: -75.17, zone: "1", url: ""),
            Station(id: "B", code: "B", name: "Destination", latitude: 39.95, longitude: -75.17, zone: "1", url: ""),
            Station(id: "C", code: "C", name: "Intermediate", latitude: 39.945, longitude: -75.17, zone: "1", url: "")
        ]
        let diagnosticSuite = "diagnostics-test.\(UUID().uuidString)"
        let stationDirectory = directory.appendingPathComponent("station-departures")
        let savedStationRoute = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                                              now: now, directory: stationDirectory)!
        let stationRoute = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 1,
            originId: "C", destinationId: "B", stations: stations, now: now.addingTimeInterval(1), directory: stationDirectory)!
        precondition(stationRoute.originId == "C" && stationRoute.destinationId == "B" && stationRoute.manual)
        precondition(stationRoute.savedOriginId == savedStationRoute.savedOriginId && stationRoute.savedDestinationId == "B")
        let staleStationSelection = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 1,
            originId: "A", destinationId: "B", stations: stations, directory: stationDirectory)!
        precondition(staleStationSelection == stationRoute)
        let stationRefresh = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", expectedRevision: 2,
            observationAt: now.addingTimeInterval(2), now: now.addingTimeInterval(2), directory: stationDirectory)!
        precondition(stationRefresh == stationRoute)
        for invalidPair in [("missing", "B"), ("C", "missing"), ("C", "C")] {
            precondition(SharedRouteCoordinator.selectStationDepartures(expectedRevision: 2,
                originId: invalidPair.0, destinationId: invalidPair.1, stations: stations,
                directory: stationDirectory) == stationRoute)
        }
        let restoredStationRoute = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 2,
            originId: "A", destinationId: "B", stations: stations, now: now.addingTimeInterval(3), directory: stationDirectory)!
        precondition(restoredStationRoute.originId == "A" && restoredStationRoute.destinationId == "B")
        precondition(restoredStationRoute.savedOriginId == "A" && restoredStationRoute.savedDestinationId == "B")
        let diagnosticDefaults = UserDefaults(suiteName: diagnosticSuite)!
        defer { diagnosticDefaults.removePersistentDomain(forName: diagnosticSuite) }
        precondition(SharedDiagnosticState.snapshot(for: .app, defaults: diagnosticDefaults) == nil)
        SharedDiagnosticState.record(.app, origin: stations[0], destination: stations[1], revision: 1,
                                     at: now, defaults: diagnosticDefaults)
        SharedDiagnosticState.record(.homeScreen, origin: stations[1], destination: stations[0], revision: 2,
                                     at: now, nextRequestedAt: now.addingTimeInterval(180),
                                     appliedSpecialSchedules: ["Special service"], defaults: diagnosticDefaults)
        precondition(SharedDiagnosticState.snapshot(for: .app, defaults: diagnosticDefaults)?.revision == 1)
        let widgetSnapshot = SharedDiagnosticState.snapshot(for: .homeScreen, defaults: diagnosticDefaults)!
        precondition(widgetSnapshot.routeTitle == "Destination to Origin")
        precondition(widgetSnapshot.nextRequestedAt == now.addingTimeInterval(180))
        precondition(widgetSnapshot.appliedSpecialSchedules == ["Special service"])
        let beforeRead = diagnosticDefaults.dictionaryRepresentation()
        _ = SharedDiagnosticState.snapshot(for: .homeScreen, defaults: diagnosticDefaults)
        precondition(NSDictionary(dictionary: beforeRead).isEqual(to: diagnosticDefaults.dictionaryRepresentation()))
        SharedDiagnosticState.record(.app, origin: stations[0], destination: stations[1], revision: 1,
                                     at: now.addingTimeInterval(5), defaults: diagnosticDefaults)
        precondition(SharedDiagnosticState.snapshot(for: .app, defaults: diagnosticDefaults)?.recordedAt == now)
        SharedDiagnosticState.record(.app, origin: stations[1], destination: stations[0], revision: 2,
                                     at: now.addingTimeInterval(6), defaults: diagnosticDefaults)
        precondition(SharedDiagnosticState.snapshot(for: .app, defaults: diagnosticDefaults)?.revision == 2)
        precondition(SharedDiagnosticState.snapshot(for: .lockScreen, defaults: diagnosticDefaults) == nil)
        func fix(_ station: Int, _ seconds: Double, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: stations[station].coordinate, altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: 1, course: 0, speed: 0, timestamp: now.addingTimeInterval(seconds))
        }
        func resolveStop(_ station: Int, _ seconds: Double, directory: URL) -> SharedRouteCoordinator.Route {
            let before = SharedRouteCoordinator.current(directory: directory)!
            let first = SharedRouteCoordinator.resolve(location: fix(station, seconds), stations: stations,
                now: now.addingTimeInterval(seconds), directory: directory)!
            let final = SharedRouteCoordinator.resolve(location: fix(station, seconds + 10), stations: stations,
                now: now.addingTimeInterval(seconds + 10), directory: directory)!
            precondition(final.revision == before.revision + 1)
            precondition(first.revision == before.revision || first.revision == final.revision,
                "A boundary crossing may confirm on the first fix; a stop fallback confirms later")
            return final
        }
        let nearestDirectory = directory.appendingPathComponent("explicit-nearest")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                         now: now, directory: nearestDirectory)
        let awayReverse = SharedRouteCoordinator.reverse(expectedRevision: 1,
            now: now.addingTimeInterval(1), directory: nearestDirectory)!
        for invalid in [fix(2, -40), fix(2, 3, accuracy: 500), fix(2, 30)] {
            let unchanged = SharedRouteCoordinator.selectNearestStation(expectedRevision: 2,
                location: invalid, stations: stations, now: now.addingTimeInterval(3), directory: nearestDirectory)!
            precondition(unchanged == awayReverse)
        }
        let midpointSelection = SharedRouteCoordinator.selectNearestStation(expectedRevision: 2,
            location: fix(2, 4), stations: stations, now: now.addingTimeInterval(4), directory: nearestDirectory)!
        precondition(midpointSelection == awayReverse)
        let nearest = SharedRouteCoordinator.selectNearestStation(expectedRevision: 2,
            location: fix(1, 4), stations: stations, now: now.addingTimeInterval(4), directory: nearestDirectory)!
        precondition(nearest.originId == "B" && nearest.destinationId == "A" && nearest.manual)
        precondition(Set([nearest.savedOriginId, nearest.savedDestinationId]) == Set(["A", "B"]))
        precondition(nearest.revision == 3 && nearest.reason == "Find nearest station")
        let staleNearest = SharedRouteCoordinator.selectNearestStation(expectedRevision: 2,
            location: fix(1, 5), stations: stations, now: now.addingTimeInterval(5), directory: nearestDirectory)!
        precondition(staleNearest == nearest)
        let ordinaryRefresh = SharedRouteCoordinator.commit(originId: "B", destinationId: "A",
            expectedRevision: 3, observationAt: now.addingTimeInterval(6), directory: nearestDirectory)!
        precondition(ordinaryRefresh == nearest)
        let nearestDestination = SharedRouteCoordinator.selectNearestStation(expectedRevision: 3,
            location: fix(0, 7), stations: stations, now: now.addingTimeInterval(7), directory: nearestDirectory)!
        precondition(nearestDestination.originId == "A" && nearestDestination.destinationId == "B")
        precondition(nearestDestination.revision == 4)
        let emptyStations = SharedRouteCoordinator.selectNearestStation(expectedRevision: 4,
            location: fix(0, 8), stations: [], now: now.addingTimeInterval(8), directory: nearestDirectory)!
        precondition(emptyStations == nearestDestination)
        let protectedDirectory = directory.appendingPathComponent("protected-reversal")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                         now: now, directory: protectedDirectory)
        let protected = SharedRouteCoordinator.reverse(expectedRevision: 1, selectionLocation: fix(0, 0),
                                stations: stations, now: now.addingTimeInterval(1), directory: protectedDirectory)!
        precondition(protected.blockedArrivalDestinationId == "A")
        let stillHere = SharedRouteCoordinator.resolve(location: fix(0, 2), stations: stations,
                                now: now.addingTimeInterval(2), directory: protectedDirectory)!
        precondition(stillHere.originId == "B" && stillHere.destinationId == "A" && stillHere.revision == 2)
        let rejectedAppArrival = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", expectedRevision: 2,
                                arrival: true, observationAt: now.addingTimeInterval(3),
                                now: now.addingTimeInterval(3), directory: protectedDirectory)!
        precondition(rejectedAppArrival.revision == 2)
        for reading in [fix(1, 4, accuracy: 500), fix(1, -40), fix(1, 10)] {
            let result = SharedRouteCoordinator.resolve(location: reading, stations: stations,
                                now: now.addingTimeInterval(5), directory: protectedDirectory)!
            precondition(result.blockedArrivalDestinationId == "A")
        }
        let departed = SharedRouteCoordinator.resolve(location: fix(2, 6), stations: stations,
                                now: now.addingTimeInterval(6), directory: protectedDirectory)!
        precondition(departed.blockedArrivalDestinationId == nil && departed.revision == 2)
        precondition(departed.manual)
        // Opening the app or receiving newer GPS cannot undo a widget reversal,
        // even with the correct revision, no reading, or no active arrival block.
        for observation in [nil, now.addingTimeInterval(6), now.addingTimeInterval(3600)] as [Date?] {
            let automatic = SharedRouteCoordinator.commit(originId: "A", destinationId: "B",
                expectedRevision: 2, observationAt: observation,
                now: now.addingTimeInterval(3600), directory: protectedDirectory)!
            precondition(automatic == departed)
        }
        let intermediateAppRoute = SharedRouteCoordinator.commit(originId: "C", destinationId: "A",
            expectedRevision: 2, observationAt: now.addingTimeInterval(6),
            now: now.addingTimeInterval(6), directory: protectedDirectory)!
        precondition(intermediateAppRoute == departed)
        let returnedAfterLeaving = resolveStop(0, 7, directory: protectedDirectory)
        precondition(returnedAfterLeaving.originId == "A" && returnedAfterLeaving.destinationId == "B")
        precondition(!returnedAfterLeaving.manual)
        precondition(SharedRouteCoordinator.selectedStations(in: stations, directory: protectedDirectory)?.origin.id == "A")
        precondition(SharedRouteCoordinator.selectedStations(in: [], directory: protectedDirectory) == nil)
        let appArrivalDirectory = directory.appendingPathComponent("manual-app-arrival")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
            now: now, directory: appArrivalDirectory)
        let appArrival = SharedRouteCoordinator.commit(originId: "B", destinationId: "A",
            expectedRevision: 1, arrival: true, observationAt: now.addingTimeInterval(10),
            now: now.addingTimeInterval(10), directory: appArrivalDirectory)!
        precondition(appArrival.revision == 2 && !appArrival.manual)
        precondition(appArrival.originId == "B" && appArrival.destinationId == "A")
        let explicitChange = SharedRouteCoordinator.commit(originId: "A", destinationId: "C", manual: true,
            now: now.addingTimeInterval(11), directory: appArrivalDirectory)!
        precondition(explicitChange.revision == 3 && explicitChange.manual)
        precondition(explicitChange.destinationId == "C")
        // Each manual selection replaces old suppression, including a return to the original destination.
        _ = SharedRouteCoordinator.commit(originId: "B", destinationId: "A", manual: true,
                                selectionLocation: fix(0, 8), destinationLocation: stations[0].location,
                                now: now.addingTimeInterval(8), directory: protectedDirectory)
        let changedAway = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                selectionLocation: fix(0, 9), destinationLocation: stations[1].location,
                                now: now.addingTimeInterval(9), directory: protectedDirectory)!
        precondition(changedAway.blockedArrivalDestinationId == nil)
        let normalArrival = resolveStop(1, 10, directory: protectedDirectory)
        precondition(normalArrival.originId == "B" && normalArrival.destinationId == "A")
        let noLocation = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true,
                                now: now.addingTimeInterval(11), directory: protectedDirectory)!
        precondition(noLocation.blockedArrivalDestinationId == nil)
        // Existing installed route snapshots decode without the newly added optional field.
        let legacyFile = protectedDirectory.appendingPathComponent("resolved-route.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        legacy.removeValue(forKey: "blockedArrivalDestinationId")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyFile)
        precondition(SharedRouteCoordinator.current(directory: protectedDirectory)?.revision == noLocation.revision)
        let intermediate = SharedRouteCoordinator.resolve(location: fix(2, 1), stations: stations,
                                  now: now.addingTimeInterval(1), directory: directory)!
        precondition(intermediate.originId == "A" && intermediate.revision == 1)
        let arrival = resolveStop(1, 10, directory: directory)
        precondition(arrival.originId == "B" && arrival.destinationId == "A" && arrival.revision == 2)
        // An old app snapshot cannot undo the background arrival.
        let staleWriter = SharedRouteCoordinator.commit(originId: "A", destinationId: "B",
                                   expectedRevision: 1, directory: directory)!
        precondition(staleWriter.revision == 2 && staleWriter.originId == "B")
        let cachedAppWrite = SharedRouteCoordinator.commit(originId: "A", destinationId: "B",
                                    expectedRevision: 2, observationAt: now.addingTimeInterval(5),
                                    directory: directory)!
        precondition(cachedAppWrite.revision == 2 && cachedAppWrite.originId == "B")
        let oldFix = SharedRouteCoordinator.resolve(location: fix(0, 5), stations: stations,
                                   now: now.addingTimeInterval(11), directory: directory)!
        precondition(oldFix.revision == 2)
        let duplicate = SharedRouteCoordinator.resolve(location: fix(1, 10), stations: stations,
                                   now: now.addingTimeInterval(12), directory: directory)!
        precondition(duplicate.revision == 2)
        let manual = SharedRouteCoordinator.commit(originId: "A", destinationId: "C", manual: true,
                                  now: now.addingTimeInterval(20), directory: directory)!
        precondition(manual.revision == 3)
        let staleDestination = SharedRouteCoordinator.resolve(location: fix(1, 15), stations: stations,
                                  now: now.addingTimeInterval(21), directory: directory)!
        precondition(staleDestination == manual)
        let poor = SharedRouteCoordinator.resolve(location: fix(2, 22, accuracy: 200), stations: stations,
                                  now: now.addingTimeInterval(22), directory: directory)!
        precondition(poor == manual)

        let changesDirectory = directory.appendingPathComponent("changes")
        for (index, destination) in ["C", "B", "C", "B"].enumerated() {
            _ = SharedRouteCoordinator.commit(originId: "A", destinationId: destination, manual: true,
                                             now: now.addingTimeInterval(Double(index + 30)), directory: changesDirectory)
        }
        let neighbor = Station(id: "D", code: "D", name: "Neighbor", latitude: 39.9501, longitude: -75.17, zone: "1", url: "")
        let ambiguous = SharedRouteCoordinator.resolve(location: fix(1, 40), stations: stations + [neighbor],
                                  now: now.addingTimeInterval(40), directory: changesDirectory)!
        precondition(ambiguous.revision == 4)
        let originalArrival = resolveStop(1, 41, directory: changesDirectory)
        precondition(originalArrival.revision == 5 && originalArrival.destinationId == "A")
        let returned = resolveStop(0, 52, directory: changesDirectory)
        precondition(returned.revision == 6 && returned.originId == "A" && returned.destinationId == "B")

        let raceDirectory = directory.appendingPathComponent("race")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", directory: raceDirectory)
        let processes = try (0..<8).map { index -> Process in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [raceDirectory.path, "writer\(index)", "race"]
            try process.run()
            return process
        }
        for process in processes {
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        precondition(SharedRouteCoordinator.current(directory: raceDirectory)?.revision == 2)
        print("Shared route checks passed, including eight competing processes")
    }
}
