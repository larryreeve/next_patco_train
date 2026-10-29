import Foundation

struct PATCOFare {
    let oneWayCents: Int

    init(origin: Station, destination: Station) {
        oneWayCents = Self.oneWayFareCents(origin: origin, destination: destination)
    }

    var oneWayText: String {
        Self.currencyText(cents: oneWayCents)
    }

    var roundTripText: String {
        Self.currencyText(cents: oneWayCents * 2)
    }

    private static func oneWayFareCents(origin: Station, destination: Station) -> Int {
        if isPhiladelphia(origin), isPhiladelphia(destination) {
            return 140
        }

        if isBroadwayCityHallPair(origin, destination) {
            return 140
        }

        if isPhiladelphia(origin) || isPhiladelphia(destination) {
            let newJerseyStation = isPhiladelphia(origin) ? destination : origin
            switch newJerseyStation.name {
            case "Lindenwold", "Ashland", "Woodcrest":
                return 300
            case "Haddonfield", "Westmont", "Collingswood":
                return 260
            case "Ferry Avenue":
                return 225
            case "Broadway", "City Hall":
                return 140
            default:
                return 160
            }
        }

        return 160
    }

    private static func isPhiladelphia(_ station: Station) -> Bool {
        station.name == "Franklin Square"
            || station.name == "8th and Market"
            || station.name == "9/10th and Locust"
            || station.name == "12/13th and Locust"
            || station.name == "15/16th and Locust"
    }

    private static func isBroadwayCityHallPair(_ origin: Station, _ destination: Station) -> Bool {
        Set([origin.name, destination.name]) == Set(["Broadway", "City Hall"])
    }

    private static func currencyText(cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100)
    }
}
