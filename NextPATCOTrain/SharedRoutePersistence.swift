import Foundation

enum SharedRoutePersistence {
    enum Failure: String, Error {
        case storageUnavailable, lockFailed, readFailed, corruptData, backupFailed, writeFailed
    }

    static func report(_ failure: Failure) {
        let advice: String
        switch failure {
        case .storageUnavailable: advice = "Shared storage unavailable; unlock the device and retry. Route unchanged."
        case .lockFailed: advice = "Could not acquire the shared route lock. Retry the action."
        case .readFailed: advice = "Could not read the shared route. Existing files were preserved; retry after unlocking."
        case .corruptData: advice = "Shared route is unreadable and no valid backup is available. Files preserved for recovery."
        case .backupFailed: advice = "Could not preserve the previous route. Update cancelled; check available storage."
        case .writeFailed: advice = "Could not save the route. Retry the action and check available storage."
        }
        ArrivalDiagnostics.record("Route persistence: \(failure.rawValue)", detail: advice)
        SharedWidgetDiagnostics.record("Route persistence: \(failure.rawValue)", detail: advice)
    }

    /// Called only while holding route.lock. Missing data permits bootstrap; unreadable data does not.
    static func load(root: URL) throws -> SharedRouteCoordinator.Route? {
        let file = root.appendingPathComponent("resolved-route.json")
        let backup = root.appendingPathComponent("resolved-route.backup.json")
        let data: Data?
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { data = nil }
        catch { throw Failure.readFailed }
        if let data, let route = try? JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: data) { return route }
        let backupData: Data?
        do { backupData = try Data(contentsOf: backup) }
        catch CocoaError.fileReadNoSuchFile { backupData = nil }
        catch { throw Failure.readFailed }
        guard let backupData,
              let restored = try? JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: backupData) else {
            if data == nil && backupData == nil { return nil }
            throw Failure.corruptData
        }
        do {
            if let data {
                // Preserve damaged bytes before restoring; never quietly bootstrap over them.
                try data.write(to: root.appendingPathComponent("resolved-route.corrupt-\(UUID().uuidString).json"), options: .atomic)
            }
        } catch { throw Failure.backupFailed }
        do { try backupData.write(to: file, options: .atomic) }
        catch { throw Failure.writeFailed }
        ArrivalDiagnostics.record("Route restored from backup", detail: "Recovered revision \(restored.revision); damaged data preserved. Most recent changes may need to be repeated.")
        SharedWidgetDiagnostics.record("Route restored from backup", detail: "Recovered revision \(restored.revision)")
        return restored
    }

    static func save(_ route: SharedRouteCoordinator.Route, previous: SharedRouteCoordinator.Route?, root: URL,
                     beforeCommit: () throws -> Void = {}) throws {
        if let previous {
            do {
                try JSONEncoder().encode(previous).write(to: root.appendingPathComponent("resolved-route.backup.json"), options: .atomic)
            } catch { throw Failure.backupFailed }
        }
        // A test seam for process death after backup but before the atomic commit.
        try beforeCommit()
        do {
            try JSONEncoder().encode(route).write(to: root.appendingPathComponent("resolved-route.json"), options: .atomic)
        } catch { throw Failure.writeFailed }
    }
}
