#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import Foundation
import CoreLocation

struct LocationRaceCheck {
    static let stations = [("A", 39.98), ("C", 39.965), ("B", 39.95)].map { id, latitude in
        Station(id: id, code: id, name: id, latitude: latitude, longitude: -75.16, zone: "1", url: "")
    }
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let now = base.addingTimeInterval(10)
        let location = CLLocation(coordinate: stations[2].coordinate, altitude: 0, horizontalAccuracy: 20,
            verticalAccuracy: 1, timestamp: now)
        if CommandLine.arguments.count == 4 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let index = CommandLine.arguments[2]
            let mode = CommandLine.arguments[3]
            try Data().write(to: directory.appendingPathComponent("ready-\(index)"))
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) {
                guard Date() < deadline else { preconditionFailure("Race barrier timed out") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            switch mode {
            case "reverse": _ = SharedRouteCoordinator.reverse(expectedRevision: 2, now: now, directory: directory)
            case "arrival":
                if SharedRouteCoordinator.checkArrival(expectedRevision: 2, location: location,
                    stations: stations, now: now, directory: directory)?.confirmed == true {
                    _ = SharedRouteCoordinator.commit(originId: "B", destinationId: "A", expectedRevision: 2,
                        arrival: true, observationAt: now, now: now, directory: directory)
                }
            case "restore": _ = SharedRouteCoordinator.restoreStationRoute(expectedRevision: 2, now: now, directory: directory)
            case "station": _ = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 2,
                originId: "A", destinationId: "B", stations: stations, now: now, directory: directory)
            case "evidence": _ = SharedRouteCoordinator.checkArrival(expectedRevision: 2,
                location: location, stations: stations, now: now, directory: directory)
            default: preconditionFailure("Unknown worker action")
            }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for round in 0..<12 {
            let directory = root.appendingPathComponent("round-\(round)")
            _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: base, directory: directory)
            _ = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 1, originId: "C", destinationId: "B",
                stations: stations, automatic: true, now: base.addingTimeInterval(1), directory: directory)
            let session = JourneyProgressSession(key: "race", deepLink: "patconext://departure?origin=A&destination=B&departure=1800000000",
                originName: "A", destinationName: "B", departure: base, arrival: base.addingTimeInterval(600), stops: [])
            _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: 2, now: base, directory: directory)
            var workers: [Process] = []
            for (index, mode) in ["reverse", "arrival", "restore", "station", "evidence", "reverse", "arrival", "evidence"].enumerated() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = [directory.path, String(index), mode]
                try process.run()
                workers.append(process)
            }
            let deadline = Date().addingTimeInterval(10)
            while (try FileManager.default.contentsOfDirectory(atPath: directory.path)).filter({ $0.hasPrefix("ready-") }).count < workers.count {
                guard Date() < deadline else {
                    workers.forEach { if $0.isRunning { $0.terminate() } }
                    preconditionFailure("Workers did not reach barrier")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            try Data().write(to: directory.appendingPathComponent("go"))
            for process in workers { process.waitUntilExit(); precondition(process.terminationStatus == 0) }
            let route = SharedRouteCoordinator.current(directory: directory)!
            precondition(route.revision == 3 && route.originId != route.destinationId)
            precondition(route.journey?.key == "race")
            if route.completesJourney { precondition(route.journey?.termination == .arrived) }
            else if route.event == .reversal { precondition(route.journey?.termination == .cancelled) }
            else { precondition(route.journey?.isActive(at: now) == true) }
            precondition(stations.contains { $0.id == route.originId } && stations.contains { $0.id == route.destinationId })
            if route.reason == "Manual reversal" { precondition(route.manual && route.arrivalGate == nil && route.temporaryRoute == nil) }
            if route.reason == "App arrival" { precondition(route.originId == "B" && route.destinationId == "A" && route.temporaryRoute == nil) }
            let manual = SharedRouteCoordinator.commit(originId: "A", destinationId: "C", manual: true,
                now: now.addingTimeInterval(1), directory: directory)!
            precondition(SharedRouteCoordinator.commit(originId: "B", destinationId: "A", expectedRevision: 2,
                arrival: true, observationAt: now, now: now, directory: directory) == manual)
            precondition(SharedRouteCoordinator.checkArrival(expectedRevision: 2, location: location,
                stations: stations, now: now, directory: directory) == nil)
            precondition(SharedRouteCoordinator.current(directory: directory) == manual)
        }
        print("Location race checks passed: 96 competing process actions across arrival, reversal, restoration and evidence")
    }
}
