import Foundation
import XCTest

/// Real executables are required to test cross-process locking and killed-writer recovery.
@MainActor
enum ProcessCheckRunner {
    private static var directory: URL?

    static func run(_ name: String) throws {
        let root = TestPaths.repository
        if directory == nil {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("patco-process-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let sources = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("NextPATCOTrain/Core").path)
                .filter { $0.hasSuffix(".swift") }.sorted().map { "NextPATCOTrain/Core/" + $0 }
            let checks = ["LocationRaceCheck","RouteProcessRecoveryCheck","SharedRouteCheck","WidgetActionProgressCheck"]
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.currentDirectoryURL = root
            compiler.arguments = ["swiftc", "-module-cache-path", output.appendingPathComponent("modules").path]
                + sources + ["NextPATCOTrain/PATCOModels.swift", "NextPATCOTrain/JourneyCoordinator.swift",
                    "NextPATCOTrain/SharedRoutePersistence.swift", "Tests/Support/SourceInspection.swift",
                    "Tests/Support/ProcessCheckMain.swift"]
                + checks.map { "Tests/" + $0 + ".swift" }
                + ["-o", output.appendingPathComponent("ProcessChecks").path]
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: output)
                throw NSError(domain: "ProcessChecks.Compile", code: Int(compiler.terminationStatus))
            }
            for check in checks {
                try FileManager.default.createSymbolicLink(at: output.appendingPathComponent(check),
                    withDestinationURL: output.appendingPathComponent("ProcessChecks"))
            }
            directory = output
        }
        let process = Process()
        process.executableURL = directory!.appendingPathComponent(name)
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, name + " failed")
    }

    static func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
