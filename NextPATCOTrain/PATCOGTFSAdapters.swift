import Foundation
import ZIPFoundation

extension PATCOGTFSUpdateService {
    /// Production wiring stays outside the update pipeline so tests never use shared storage or networking.
    static let shared = PATCOGTFSUpdateService(dependencies: .init(
        defaults: UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard,
        fetch: { try await URLSession.shared.data(for: $0) },
        extract: PATCOGTFSArchive.extract,
        loadMetadata: { PATCOFeedCache.loadMetadata() },
        save: { try PATCOFeedCache.save($0, metadata: $1) }))
}

enum PATCOGTFSArchive {
    static func extract(_ archiveData: Data) throws -> [String: Data] {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PATCO-\(UUID().uuidString).zip")
        try archiveData.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let archive = try Archive(url: temporaryURL, accessMode: .read)
        let required = ["agency.txt", "feed_info.txt", "routes.txt", "stops.txt",
                        "calendar.txt", "calendar_dates.txt", "trips.txt", "stop_times.txt"]
        var files: [String: Data] = [:]
        for filename in required {
            guard let entry = archive[filename], entry.uncompressedSize <= 10_000_000 else {
                throw PATCOGTFSUpdateError.missingRequiredFile(filename)
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            files[filename] = data
        }
        return files
    }
}
