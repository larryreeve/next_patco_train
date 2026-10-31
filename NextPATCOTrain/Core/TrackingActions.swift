import Foundation

/// Commits journey state before running platform effects. Dependencies are supplied by the app.
@MainActor
struct TrackingActions {
    var current: () -> SharedRouteCoordinator.Route?
    var cancelJourney: (String) -> SharedRouteCoordinator.Route?
    var confirmArrival: (String, String, Int) -> SharedRouteCoordinator.Route?
    var synchronize: () -> Void
    var stopLocation: (Bool) -> Void
    var endActivity: (String) async -> Void
    var changed: () -> Void

    func cancel(key: String) async -> Bool {
        guard let route = cancelJourney(key), route.journey?.key == key,
              route.journey?.state == .cancelled else { return false }
        synchronize()
        stopLocation(true)
        await endActivity(key)
        changed()
        return true
    }

    func arrive(originId: String, destinationId: String) -> SharedRouteCoordinator.Route? {
        guard let old = current(),
              let route = confirmArrival(originId, destinationId, old.revision),
              route.revision == old.revision + 1 else { return nil }
        synchronize()
        stopLocation(false)
        return route
    }
}

/// Replacement must be accepted before an existing platform display is removed.
@MainActor
enum TrackingDisplayReplacement {
    static func replace<Display>(previous: [Display], request: () throws -> Display,
                                 accept: (Display) -> Bool,
                                 end: @MainActor (Display) async -> Void) async throws -> Display? {
        let replacement = try request()
        guard accept(replacement) else {
            await end(replacement)
            return nil
        }
        for display in previous { await end(display) }
        return replacement
    }
}
