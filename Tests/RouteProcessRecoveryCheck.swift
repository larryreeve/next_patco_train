#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import Foundation
import Darwin

struct RouteProcessRecoveryCheck {
    static func run() throws {
        if CommandLine.arguments.count == 3 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let mode = CommandLine.arguments[2]
            let lock = open(root.appendingPathComponent("route.lock").path, O_CREAT | O_RDWR, 0o600)
            precondition(lock >= 0 && flock(lock, LOCK_EX) == 0)
            defer { flock(lock, LOCK_UN); close(lock) }
            let old = try SharedRoutePersistence.load(root: root)!
            let next = SharedRouteCoordinator.Route(originId: old.destinationId, destinationId: old.originId,
                savedOriginId: old.savedOriginId, savedDestinationId: old.savedDestinationId,
                revision: old.revision + 1, updatedAt: Date(), reason: "Manual reversal", manual: true)
            func readyAndWait() throws {
                try Data().write(to: root.appendingPathComponent("ready"))
                // The parent deliberately kills this writer while it owns the lock.
                while true { Thread.sleep(forTimeInterval: 0.01) }
            }
            try SharedRoutePersistence.save(next, previous: old, root: root) {
                if mode == "before-commit" { try readyAndWait() }
            }
            try readyAndWait()
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["before-commit", "after-commit"] {
            let directory = root.appendingPathComponent(mode)
            let old = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, directory: directory)!
            let writer = Process()
            writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            writer.arguments = [directory.path, mode]
            try writer.run()
            defer { if writer.isRunning { kill(writer.processIdentifier, SIGKILL); writer.waitUntilExit() } }
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) {
                precondition(writer.isRunning && Date() < deadline, "Writer failed to reach interruption point")
                Thread.sleep(forTimeInterval: 0.01)
            }
            kill(writer.processIdentifier, SIGKILL)
            writer.waitUntilExit()
            precondition(writer.terminationReason == .uncaughtSignal)
            let recovered = SharedRouteCoordinator.current(directory: directory)!
            precondition(recovered.revision == old.revision + (mode == "after-commit" ? 1 : 0))
            precondition(recovered.originId == (mode == "after-commit" ? "B" : "A"))
            let updated = SharedRouteCoordinator.reverse(expectedRevision: recovered.revision, directory: directory)!
            precondition(updated.revision == recovered.revision + 1, "Process death must release the route lock")
            precondition(SharedRouteCoordinator.reverse(expectedRevision: old.revision, directory: directory) == updated,
                         "A stale widget cannot overwrite the relaunched app's route")
            // An unrelated partial temporary file must never be treated as the committed route.
            try Data("{partial".utf8).write(to: directory.appendingPathComponent("interrupted-save.tmp"))
            precondition(SharedRouteCoordinator.current(directory: directory) == updated)
        }
        print("Route process recovery checks passed: killed writers before/after commit, lock release, relaunch and stale widget updates")
    }
}
