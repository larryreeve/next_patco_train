import Foundation
import Observation

/// Owns browsing dates and schedule refresh/recovery state, not the active journey.
@MainActor @Observable
final class HomeScheduleController {
    let store: PATCOScheduleStore
    let specialSchedules: PATCOSpecialScheduleProvider
    var selectedScheduleDate = Date()
    var draftScheduleDate = Date()
    var isCheckingFutureSpecialSchedule = false
    var futureSpecialScheduleCheckFailed = false
    var isScheduleRecoveryRefreshing = false
    var scheduleRecoveryMessage: String?

    init(store: PATCOScheduleStore = PATCOScheduleStore(),
         specialSchedules: PATCOSpecialScheduleProvider = PATCOSpecialScheduleProvider()) {
        self.store = store
        self.specialSchedules = specialSchedules
    }

    var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    var isViewingToday: Bool {
        patcoCalendar.isDate(selectedScheduleDate, inSameDayAs: Date())
    }

    var lastSelectableScheduleDate: Date {
        max(patcoCalendar.startOfDay(for: Date()), store.scheduleFeedEndDate ?? Date())
    }

    var isUsingCachedSchedule: Bool {
        specialSchedules.errorMessage != nil && store.activeSpecialSchedule != nil
    }

    @MainActor
    func forceGTFSUpdate(
        progress: @escaping @MainActor (PATCOGTFSUpdateService.UpdateStage) -> Void,
        onUpdated: (Bool) -> Void, onReload: (String) -> Void
    ) async -> String {
        guard let currentFeed = store.baseScheduleFeed else {
            return "Unable to refresh the schedule because the current schedule could not be loaded."
        }

        let result = await PATCOGTFSUpdateService.shared.updateIfNeeded(
            currentFeed: currentFeed,
            force: true,
            progress: progress
        )
        switch result {
        case .updated:
            progress(.reloading)
            store.load()
            applyCachedSpecialSchedules()
            onUpdated(true)
            onUpdated(false)
            onReload("Schedule updated")
            return "Schedule updated."
        case .current:
            // A successful unchanged check still updates the cached check timestamp.
            store.load()
            applyCachedSpecialSchedules()
            onUpdated(false)
            return "Current schedule is the latest."
        case .notNeeded:
            return "Current schedule is the latest."
        case .failed:
            return "Unable to refresh the schedule. Try again."
        }
    }

    var selectedScheduleDateHeaderText: String {
        let formatter = DateFormatter()
        formatter.calendar = patcoCalendar
        formatter.timeZone = patcoCalendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: selectedScheduleDate)
    }

    var sharedSpecialSchedules: [PATCOSpecialSchedule] {
        let dates = (-1...1).compactMap { patcoCalendar.date(byAdding: .day, value: $0, to: Date()) }
        return SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar)
    }

    @MainActor
    func refreshScheduleFeed(onUpdated: (Bool) -> Void, onReload: (String) -> Void) async {
        if let currentFeed = store.baseScheduleFeed {
            let updateResult = await PATCOGTFSUpdateService.shared.updateIfNeeded(currentFeed: currentFeed)
            guard !Task.isCancelled else { return }
            if case .updated = updateResult {
                store.load()
                applyCachedSpecialSchedules()
                onUpdated(true)
                onUpdated(false)
                onReload("Automatic schedule update")
            } else if case .current = updateResult {
                // An unchanged successful download still advances the schedule-check timestamp.
                store.load()
                applyCachedSpecialSchedules()
            }
        }

    }

    func applyCachedSpecialSchedules() {
        let now = Date()
        var dates = [now]
        if let yesterday = patcoCalendar.date(byAdding: .day, value: -1, to: now) {
            dates.append(yesterday)
        }
        if let tomorrow = patcoCalendar.date(byAdding: .day, value: 1, to: now) {
            dates.append(tomorrow)
        }
        if !isViewingToday {
            dates.append(selectedScheduleDate)
            if let previousSelectedDay = patcoCalendar.date(byAdding: .day, value: -1, to: selectedScheduleDate) {
                dates.append(previousSelectedDay)
            }
        }
        let schedules = SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar)
        store.applySpecialSchedules(schedules)
    }

    @MainActor
    func checkFutureSpecialSchedule(for date: Date, onUpdated: () -> Void) async {
        isCheckingFutureSpecialSchedule = true
        futureSpecialScheduleCheckFailed = false
        let result = await SharedSpecialScheduleCache.refreshIfNeeded(from: date, calendar: patcoCalendar)
        guard !Task.isCancelled, patcoCalendar.isDate(selectedScheduleDate, inSameDayAs: date) else { return }
        applyCachedSpecialSchedules()
        onUpdated()
        futureSpecialScheduleCheckFailed = result.failed
        isCheckingFutureSpecialSchedule = false
    }

}
