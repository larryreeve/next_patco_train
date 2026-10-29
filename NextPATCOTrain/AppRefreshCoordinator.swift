import Observation
import Foundation

/// Independent, coalesced refresh lanes. No network lane gates location acquisition.
@MainActor @Observable
final class AppRefreshCoordinator {
    enum Lane: Hashable { case specialSchedules, scheduleFeed, alerts, travelEstimates }
    private(set) var running: Set<Lane> = []
    var isRefreshing: Bool { !running.isEmpty }

    func run(_ lane: Lane, operation: @MainActor () async -> Void) async {
        guard !Task.isCancelled, running.insert(lane).inserted else { return }
        defer { running.remove(lane) }
        await operation()
    }

    func refresh(requestLocation: @MainActor () -> Void,
                 specialSchedules: @MainActor () async -> Void,
                 scheduleFeed: @MainActor () async -> Void,
                 alerts: @MainActor () async -> Void,
                 travelEstimates: @MainActor () async -> Void) async {
        guard !Task.isCancelled else { return }
        requestLocation()
        async let special: Void = run(.specialSchedules, operation: specialSchedules)
        async let feed: Void = run(.scheduleFeed, operation: scheduleFeed)
        async let serviceAlerts: Void = run(.alerts, operation: alerts)
        async let travel: Void = run(.travelEstimates, operation: travelEstimates)
        _ = await (special, feed, serviceAlerts, travel)
    }
}
