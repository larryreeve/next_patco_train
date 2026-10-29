import Combine
import Foundation
import WidgetKit

/// Coalesces reload requests while ensuring the shared snapshot is committed first.
@MainActor
final class WidgetReloadCoordinator: ObservableObject {
    private var lastRequestAt: Date?
    private var pending: Task<Void, Never>?
    private(set) var pendingAt: Date?
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let reload: () -> Void

    init(now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }, reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.now = now
        self.sleep = sleep
        self.reload = reload
    }

    func request(reason: String, force: Bool = false,
                 isActive: @escaping () -> Bool, publish: @escaping (Date) -> Void) {
        guard isActive() || force else { return }
        let date = now()
        let interval: TimeInterval = force ? 2 : 60
        if let lastRequestAt, date >= lastRequestAt, date.timeIntervalSince(lastRequestAt) < interval {
            let deadline = lastRequestAt.addingTimeInterval(interval)
            if let pendingAt, pendingAt <= deadline { return }
            pending?.cancel()
            pendingAt = deadline
            pending = Task { [weak self] in
                guard let self else { return }
                do { try await sleep(deadline.timeIntervalSince(date) + 0.05) }
                catch { return }
                guard !Task.isCancelled else { return }
                pendingAt = nil
                pending = nil
                request(reason: reason, force: force, isActive: isActive, publish: publish)
            }
            SharedWidgetDiagnostics.record("App widget reload skipped", detail: "\(reason) throttled")
            return
        }
        pending?.cancel()
        pending = nil
        pendingAt = nil
        lastRequestAt = date
        publish(date)
        SharedWidgetDiagnostics.record("App requested widget reload", detail: reason)
        reload()
    }
}
