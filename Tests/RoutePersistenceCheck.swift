#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct RoutePersistenceCheck {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        require(try SharedRoutePersistence.load(root: root) == nil)
        let first = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", directory: root)!
        let file = root.appendingPathComponent("resolved-route.json")
        let backup = root.appendingPathComponent("resolved-route.backup.json")
        let firstBytes = try Data(contentsOf: file)
        let second = SharedRouteCoordinator.reverse(expectedRevision: first.revision, directory: root)!
        XCTAssertTrue(second.revision == first.revision + 1)
        let savedBackup = try JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: Data(contentsOf: backup))
        XCTAssertTrue(savedBackup == first)
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: file)
        let recovered = SharedRouteCoordinator.current(directory: root)!
        XCTAssertTrue(recovered == first)
        let damaged = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("resolved-route.corrupt-") }
        XCTAssertTrue(damaged.count == 1)
        require(try Data(contentsOf: damaged[0]) == corrupt)

        // Corruption without a backup must not be treated as first launch, even for manual route selection.
        try FileManager.default.removeItem(at: backup)
        try corrupt.write(to: file)
        XCTAssertTrue(SharedRouteCoordinator.commit(originId: "C", destinationId: "D", manual: true, directory: root) == nil)
        require(try Data(contentsOf: file) == corrupt)
        expect(.corruptData) { _ = try SharedRoutePersistence.load(root: root) }

        try firstBytes.write(to: file)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        expect(.backupFailed) { try SharedRoutePersistence.save(second, previous: first, root: root) }
        require(try Data(contentsOf: file) == firstBytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        expect(.readFailed) { _ = try SharedRoutePersistence.load(root: root) }
        expect(.writeFailed) { try SharedRoutePersistence.save(second, previous: nil, root: root) }
        print("Route persistence checks passed: missing, recovery, quarantine, corruption protection, read/backup/write failures")
    }

    static func require(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, file: file, line: line)
    }

    static func expect(_ failure: SharedRoutePersistence.Failure, operation: () throws -> Void) {
        do { try operation(); XCTFail("Expected \(failure)") }
        catch { XCTAssertTrue(error as? SharedRoutePersistence.Failure == failure, "Unexpected error: \(error)") }
    }
}
