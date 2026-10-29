#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripBackfillCheck {
    static func run() throws {
        struct Feed: Decodable { let stops: [Station] }
        let feed = try JSONDecoder().decode(Feed.self, from: Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let geometry = try JSONDecoder().decode(PATCOTrackGeometry.self, from: Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_tracks.json")))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let west = feed.stops.filter { (2...14).contains(Int($0.code) ?? 0) }.sorted { Int($0.code)! < Int($1.code)! }
        let east = Array(west.reversed())
        func reading(accuracy: Double = 10, age: Double = 0, longitude: Double = -75.138146) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 39.953566, longitude: longitude), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: 18,
                       timestamp: now.addingTimeInterval(-age))
        }
        func observe(_ fix: CLLocation, stations: [Station], departure: Date? = nil) -> TripLocationProgress {
            var result = TripLocationProgress()
            result.observe(fix, stations: stations, geometry: geometry,
                           departure: departure ?? now.addingTimeInterval(-600),
                           arrival: now.addingTimeInterval(600), now: now)
            return result
        }
        let eastProgress = observe(reading(), stations: east)
        let cityIds = Set(east.filter { (10...14).contains(Int($0.code)!) }.map(\.id))
        XCTAssertTrue(eastProgress.completedStationIds == cityIds, "Eastbound bridge fix must fill Philadelphia only")
        XCTAssertTrue(eastProgress.detectedStationIds.isEmpty, "Bridge fix is passage evidence, not station arrival")
        let westProgress = observe(reading(), stations: west)
        XCTAssertTrue(westProgress.completedStationIds.isDisjoint(with: cityIds), "Westbound bridge fix must not fill Philadelphia ahead")
        XCTAssertTrue(westProgress.completedStationIds.contains(west.first { $0.code == "9" }!.id))
        for fix in [reading(accuracy: 1414), reading(age: 16), reading(age: -1), reading(longitude: -75.13)] {
            XCTAssertTrue(observe(fix, stations: east).completedStationIds.isEmpty, "Unreliable or off-track fix cannot backfill")
        }
        XCTAssertTrue(observe(reading(), stations: east, departure: now.addingTimeInterval(60)).completedStationIds.isEmpty)
        let shortTrip = east.filter { (10...12).contains(Int($0.code)!) }
        XCTAssertTrue(observe(reading(), stations: shortTrip).completedStationIds.isEmpty, "Bridge outside selected trip cannot backfill")
        let encoded = try JSONEncoder().encode(eastProgress)
        let roundTrip = try JSONDecoder().decode(TripLocationProgress.self, from: encoded)
        XCTAssertTrue(roundTrip == eastProgress)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "inferredStationIds")
        let restored = try JSONDecoder().decode(TripLocationProgress.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.inferredStationIds == nil)
        print("Trip backfill checks passed: bridge direction, route bounds, accuracy, age, persistence and legacy state")
    }
}
