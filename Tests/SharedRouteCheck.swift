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
        func fix(_ station: Int, _ seconds: Double, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: stations[station].coordinate, altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: 1, timestamp: now.addingTimeInterval(seconds))
        }
        let intermediate = SharedRouteCoordinator.resolve(location: fix(2, 1), stations: stations,
                                  now: now.addingTimeInterval(1), directory: directory)!
        precondition(intermediate.originId == "A" && intermediate.revision == 1)
        let arrival = SharedRouteCoordinator.resolve(location: fix(1, 10), stations: stations,
                                  now: now.addingTimeInterval(10), directory: directory)!
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
        let originalArrival = SharedRouteCoordinator.resolve(location: fix(1, 41), stations: stations,
                                  now: now.addingTimeInterval(41), directory: changesDirectory)!
        precondition(originalArrival.revision == 5 && originalArrival.destinationId == "A")
        let returned = SharedRouteCoordinator.resolve(location: fix(0, 50), stations: stations,
                                  now: now.addingTimeInterval(50), directory: changesDirectory)!
        precondition(returned.revision == 6 && returned.originId == "A" && returned.destinationId == "B")

        let raceDirectory = directory.appendingPathComponent("race")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, directory: raceDirectory)
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
