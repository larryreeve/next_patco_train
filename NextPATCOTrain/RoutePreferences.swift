import Foundation
import CoreLocation

struct RoutePreferences {
    static var live: Self {
        Self(defaults: UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard)
    }
    private let defaults: UserDefaults
    private let now: () -> Date
    private let currentRoute: () -> SharedRouteCoordinator.Route?
    private let selectRoute: (String, String, CLLocation?, CLLocation?) -> Void

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init,
         currentRoute: @escaping () -> SharedRouteCoordinator.Route? = { SharedRouteCoordinator.current() },
         selectRoute: @escaping (String, String, CLLocation?, CLLocation?) -> Void = {
             _ = SharedRouteCoordinator.commit(originId: $0, destinationId: $1, manual: true,
                 selectionLocation: $2, destinationLocation: $3)
         }) {
        self.defaults = defaults
        self.now = now
        self.currentRoute = currentRoute
        self.selectRoute = selectRoute
    }
    private let originKey = "defaultOriginStationId"
    private let destinationKey = "defaultDestinationStationId"
    private let temporaryOriginKey = "temporaryOriginStationId"
    private let temporaryDestinationKey = "temporaryDestinationStationId"
    private let temporarySavedAtKey = "temporaryRouteSavedAt"
    private let journeyDestinationKey = "journeyDestinationStationId"
    private let journeyDirectionSavedAtKey = "journeyDirectionSavedAt"
    private let manualStationSelectionKey = "manualStationSelectionId"

    func savedRoute() -> (originId: Station.ID, destinationId: Station.ID)? {
        if let route = currentRoute() {
            return (route.savedOriginId, route.savedDestinationId)
        }
        guard let originId = defaults.string(forKey: originKey),
              let destinationId = defaults.string(forKey: destinationKey),
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    func save(originId: Station.ID, destinationId: Station.ID,
                     selectionLocation: CLLocation? = nil, destinationLocation: CLLocation? = nil) {
        selectRoute(originId, destinationId, selectionLocation, destinationLocation)
        defaults.set(originId, forKey: originKey)
        defaults.set(destinationId, forKey: destinationKey)
    }

    func temporaryRoute(maxAge: TimeInterval = 12 * 60 * 60) -> (originId: Station.ID, destinationId: Station.ID)? {
        guard let originId = defaults.string(forKey: temporaryOriginKey),
              let destinationId = defaults.string(forKey: temporaryDestinationKey),
              let savedAt = defaults.object(forKey: temporarySavedAtKey) as? Date,
              now().timeIntervalSince(savedAt) <= maxAge,
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    func saveTemporary(originId: Station.ID, destinationId: Station.ID) {
        defaults.set(originId, forKey: temporaryOriginKey)
        defaults.set(destinationId, forKey: temporaryDestinationKey)
        defaults.set(now(), forKey: temporarySavedAtKey)
    }

    func clearTemporary() {
        defaults.removeObject(forKey: temporaryOriginKey)
        defaults.removeObject(forKey: temporaryDestinationKey)
        defaults.removeObject(forKey: temporarySavedAtKey)
    }

    func journeyDestinationId(maxAge: TimeInterval = 4 * 60 * 60) -> Station.ID? {
        guard let destinationId = defaults.string(forKey: journeyDestinationKey),
              let savedAt = defaults.object(forKey: journeyDirectionSavedAtKey) as? Date,
              now().timeIntervalSince(savedAt) <= maxAge else {
            clearJourneyDirection()
            return nil
        }
        return destinationId
    }

    func saveJourneyDirection(destinationId: Station.ID) {
        defaults.set(destinationId, forKey: journeyDestinationKey)
        defaults.set(now(), forKey: journeyDirectionSavedAtKey)
    }

    func clearJourneyDirection() {
        defaults.removeObject(forKey: journeyDestinationKey)
        defaults.removeObject(forKey: journeyDirectionSavedAtKey)
    }

    func manuallySelectedAtStationId() -> Station.ID? {
        defaults.string(forKey: manualStationSelectionKey)
    }

    func saveManualStationSelection(stationId: Station.ID) {
        defaults.set(stationId, forKey: manualStationSelectionKey)
    }

    func clearManualStationSelection() {
        defaults.removeObject(forKey: manualStationSelectionKey)
    }

}
