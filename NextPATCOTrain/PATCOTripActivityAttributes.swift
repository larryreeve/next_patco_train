import ActivityKit
import Foundation

struct PATCOTripActivityAttributes: ActivityAttributes {
    struct Stop: Codable, Hashable {
        let name: String
        let arrivalDate: Date
    }

    struct ContentState: Codable, Hashable {
        let departureDate: Date
        let arrivalDate: Date
        let stops: [Stop]
        let statusTitle: String?
        let statusDetail: String?
        let lastUpdated: Date
    }

    let routeTitle: String
    let originName: String
    let destinationName: String
    let deepLinkURLString: String

    var deepLinkURL: URL? {
        URL(string: deepLinkURLString)
    }
}
