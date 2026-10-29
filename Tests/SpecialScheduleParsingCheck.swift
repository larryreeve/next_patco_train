#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

private actor RefreshCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor RefreshBlocker {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

struct SpecialScheduleParsingCheck {
    static func run() async throws {
        var refreshCalendar = Calendar(identifier: .gregorian)
        refreshCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let refreshNow = Date(timeIntervalSince1970: 1_800_000_000)
        let appInterval = SpecialScheduleRefreshPolicy.appInterval(for: refreshNow,
            calendar: refreshCalendar, now: refreshNow)
        XCTAssertTrue(appInterval == 900)
        let tomorrow = refreshCalendar.date(byAdding: .day, value: 1, to: refreshNow)!
        XCTAssertTrue(SpecialScheduleRefreshPolicy.appInterval(for: tomorrow,
            calendar: refreshCalendar, now: refreshNow) == 3600)
        XCTAssertTrue(!SpecialScheduleRefreshPolicy.isRecent(nil, now: refreshNow, interval: appInterval))
        for (age, recent) in [(-1.0, false), (0, true), (899, true), (900, false), (901, false)] {
            XCTAssertTrue(SpecialScheduleRefreshPolicy.isRecent(refreshNow.addingTimeInterval(-age),
                now: refreshNow, interval: appInterval) == recent)
        }
        XCTAssertTrue(SpecialScheduleRefreshPolicy.isRecent(refreshNow.addingTimeInterval(-900),
            now: refreshNow, interval: SpecialScheduleRefreshPolicy.widgetInterval),
            "Widgets must retain their hourly cache interval")
        let contentSource = try SourceInspection.home()
        let refreshSource = contentSource.components(separatedBy: "func refreshAll(")[1]
            .components(separatedBy: "final class HomeScheduleController")[0]
        XCTAssertTrue(refreshSource.contains("await schedule.specialSchedules.refreshNow"))
        XCTAssertTrue(refreshSource.contains("await refreshScheduleFeed()"))
        XCTAssertTrue(refreshSource.components(separatedBy: "await schedule.specialSchedules.refreshNow").count == 2)
        XCTAssertTrue(contentSource.contains("Timer.publish(every: SpecialScheduleRefreshPolicy.todayAppInterval"))
        let blocker = RefreshBlocker()
        let timedOut = await SpecialScheduleRefreshDeadline.wait(nanoseconds: 10_000_000) {
            await blocker.wait()
            return .init(schedules: [], lastChecked: Date(), failed: false)
        }
        XCTAssertTrue(timedOut == nil, "Caller must return even when the fetch has not finished")
        await blocker.release()
        let immediate = await SpecialScheduleRefreshDeadline.wait {
            .init(schedules: [], lastChecked: Date(), failed: false)
        }
        XCTAssertTrue(immediate != nil, "Completed checks must be returned before the deadline")
        let coordinator = SpecialScheduleRefreshCoordinator()
        let counter = RefreshCounter()
        let completedAt = Date(timeIntervalSince1970: 1_790_000_000)
        await withTaskGroup(of: SharedSpecialScheduleCache.RefreshResult.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await coordinator.refresh(key: "same-day") {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        return .init(schedules: [], lastChecked: completedAt, failed: false)
                    }
                }
            }
            for await result in group {
                XCTAssertTrue(result.lastChecked == completedAt && !result.failed,
                             "Every overlapping caller must await the completed result")
            }
        }
        let count = await counter.count
        XCTAssertTrue(count == 1, "Concurrent refreshes must share one fetch")
        let retry = await coordinator.refresh(key: "same-day") {
            .init(schedules: [], lastChecked: completedAt.addingTimeInterval(1), failed: true)
        }
        XCTAssertTrue(retry.failed && retry.lastChecked != completedAt, "Completed tasks must not remain in flight")
        let provider = try String(contentsOfFile: "NextPATCOTrain/PATCOSpecialScheduleProvider.swift", encoding: .utf8)
        let app = try SourceInspection.home()
        XCTAssertTrue(app.contains(".onChange(of: model.schedule.specialSchedules.resultRevision)"))
        XCTAssertTrue(provider.contains("guard latestRequest == request, !Task.isCancelled"))
        XCTAssertTrue(provider.range(of: "replaceSchedules(fetched")!.lowerBound
                     < provider.range(of: "defaults.set(checkedAt, forKey: lastCheckKey)")!.lowerBound,
                     "A pending request must not be marked completed")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let title = "Saturday, September 26, 2026"
        let html = "<li><a href=\"https://www.ridepatco.org/schedules/TW_2026-09-26.pdf\">\(title)</a></li>"
        let links = PATCOSpecialScheduleLoader.specialScheduleLinks(
            from: html,
            baseURL: URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!,
            calendar: calendar
        )
        XCTAssertTrue(links.count == 1)
        XCTAssertTrue(calendar.dateComponents([.year, .month, .day], from: links[0].date) == DateComponents(year: 2026, month: 9, day: 26))

        let skippedRow = "12:02A 12:04A 12:05A 12:08A 12:10A 12:12A 12:14A 12:18A \u{2014} \u{2014} 12:26A \u{2014} 12:29A 12:30A"
        let fullRow = "4:45A 4:47A 4:48A 4:51A 4:53A 4:55A 4:57A 5:01A 5:03A 5:07A 5:09A 5:11A 5:12A 5:13A"
        let continued = try PATCOSpecialScheduleLoader.scheduleTrips(from:
            "WESTBOUND\n\(skippedRow)\nPage 2 - WESTBOUND continued\nStation names\n\(fullRow)\nEASTBOUND\n\(fullRow)")
        XCTAssertTrue(continued.map(\.directionId) == [0, 0, 1])
        let reversedTables = try PATCOSpecialScheduleLoader.scheduleTrips(from:
            "EASTBOUND\n\(fullRow)\nWESTBOUND\n\(skippedRow)")
        XCTAssertTrue(reversedTables.map(\.directionId) == [1, 0])
        func expectRejected(_ text: String) {
            do {
                _ = try PATCOSpecialScheduleLoader.scheduleTrips(from: text)
                XCTFail("Incomplete or ambiguous timetable was accepted")
            } catch {}
        }
        expectRejected("\(fullRow)\nEASTBOUND\n\(fullRow)")
        expectRejected("WESTBOUND\n\(fullRow)")
        expectRejected("WESTBOUND EASTBOUND\n\(fullRow)")
        let truncatedRow = fullRow.split(separator: " ").dropLast().joined(separator: " ")
        expectRejected("WESTBOUND\n\(fullRow)\n\(truncatedRow)\nEASTBOUND\n\(fullRow)")
        let times = PATCOSpecialScheduleLoader.normalizedTripTimes(from: skippedRow)!
        XCTAssertTrue(times.count == 14)
        XCTAssertTrue(times[8].isEmpty && times[9].isEmpty && times[11].isEmpty)
        XCTAssertTrue(times[10] == "00:26:00")

        if let pdfPath = ProcessInfo.processInfo.environment["PATCO_TEST_SCHEDULE_PDF"] {
            let pdfData = try Data(contentsOf: URL(fileURLWithPath: pdfPath))
            let schedule = try PATCOSpecialScheduleLoader.parseSpecialSchedulePDF(
                data: pdfData,
                title: title,
                serviceDate: links[0].date,
                sourceURL: links[0].url
            )
            XCTAssertTrue(schedule.trips.contains { $0.stopTimes.contains("") })
            XCTAssertTrue(schedule.trips.contains { !$0.stopTimes.contains("") })

            let feedData = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
            let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: feedData))
            store.applySpecialSchedule(schedule)
            let origin = store.stations.first { $0.name == "Ashland" }!
            let destination = store.stations.first { $0.name == "15/16th and Locust" }!
            let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26))!
            let departures = store.departures(from: origin, to: destination, after: start, limit: 10)
            XCTAssertTrue(!departures.isEmpty)
            XCTAssertTrue(departures.allSatisfy { departure in
                departure.trip.stopTimes.allSatisfy { !$0.arrival.isEmpty && !$0.departure.isEmpty }
            })
            XCTAssertTrue(departures[0].trip.stopTimes.count == 11)
            XCTAssertTrue(!departures[0].trip.stopTimes.contains { $0.stopId == store.stations[8].id })
            let firstTime = calendar.dateComponents([.hour, .minute], from: departures[0].departureDate)
            XCTAssertTrue(firstTime == DateComponents(hour: 0, minute: 4), "First Saturday Ashland departure was \(firstTime)")

            let departuresIncludingRemoved = store.departures(
                from: origin,
                to: destination,
                after: start,
                limit: nil,
                includingRemovedSpecialScheduleDepartures: true
            )
            let activeDepartureTimes = Set(departuresIncludingRemoved.filter { !$0.isRemovedBySpecialSchedule }.map(\.departureDate))
            let removedDepartureTimes = Set(departuresIncludingRemoved.filter(\.isRemovedBySpecialSchedule).map(\.departureDate))
            XCTAssertTrue(
                activeDepartureTimes.isDisjoint(with: removedDepartureTimes),
                "Duplicate active/removed times: \(activeDepartureTimes.intersection(removedDepartureTimes).sorted())"
            )
            let firstPublishedDeparture = departuresIncludingRemoved.first {
                !$0.isRemovedBySpecialSchedule
                    && calendar.dateComponents([.hour, .minute], from: $0.departureDate) == DateComponents(hour: 0, minute: 4)
            }
            XCTAssertTrue(
                firstPublishedDeparture?.scheduleAdjustment?.originalDepartureDate.map {
                    calendar.dateComponents([.hour, .minute], from: $0)
                } == DateComponents(hour: 0, minute: 2),
                "Expected the 12:04 AM special departure to replace the 12:02 AM standard departure."
            )
            XCTAssertTrue(
                !departuresIncludingRemoved.contains {
                    $0.isRemovedBySpecialSchedule
                        && calendar.dateComponents([.hour, .minute], from: $0.departureDate) == DateComponents(hour: 0, minute: 2)
                },
                "The 12:02 AM departure should be adjusted, not listed as removed."
            )
            print("Saturday PDF parsed: \(schedule.trips.count) trips")
        }

        if let pagePath = ProcessInfo.processInfo.environment["PATCO_TEST_SCHEDULE_PAGE"] {
            let page = try String(contentsOfFile: pagePath, encoding: .utf8)
            let pageLinks = PATCOSpecialScheduleLoader.specialScheduleLinks(
                from: page,
                baseURL: URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!,
                calendar: calendar
            )
            XCTAssertTrue(pageLinks.contains { $0.url.lastPathComponent == "TW_2026-09-26.pdf" })
        }

        print("Special schedule parsing checks passed")
    }
}
