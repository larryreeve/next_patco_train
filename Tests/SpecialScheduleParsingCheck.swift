import Foundation

@main
struct SpecialScheduleParsingCheck {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let title = "Saturday, September 26, 2026"
        let html = "<li><a href=\"https://www.ridepatco.org/schedules/TW_2026-09-26.pdf\">\(title)</a></li>"
        let links = PATCOSpecialScheduleLoader.specialScheduleLinks(
            from: html,
            baseURL: URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!,
            calendar: calendar
        )
        precondition(links.count == 1)
        precondition(calendar.dateComponents([.year, .month, .day], from: links[0].date) == DateComponents(year: 2026, month: 9, day: 26))

        let skippedRow = "12:02A 12:04A 12:05A 12:08A 12:10A 12:12A 12:14A 12:18A \u{2014} \u{2014} 12:26A \u{2014} 12:29A 12:30A"
        let fullRow = "4:45A 4:47A 4:48A 4:51A 4:53A 4:55A 4:57A 5:01A 5:03A 5:07A 5:09A 5:11A 5:12A 5:13A"
        let continued = try PATCOSpecialScheduleLoader.scheduleTrips(from:
            "WESTBOUND\n\(skippedRow)\nPage 2 - WESTBOUND continued\nStation names\n\(fullRow)\nEASTBOUND\n\(fullRow)")
        precondition(continued.map(\.directionId) == [0, 0, 1])
        let reversedTables = try PATCOSpecialScheduleLoader.scheduleTrips(from:
            "EASTBOUND\n\(fullRow)\nWESTBOUND\n\(skippedRow)")
        precondition(reversedTables.map(\.directionId) == [1, 0])
        func expectRejected(_ text: String) {
            do {
                _ = try PATCOSpecialScheduleLoader.scheduleTrips(from: text)
                preconditionFailure("Incomplete or ambiguous timetable was accepted")
            } catch {}
        }
        expectRejected("\(fullRow)\nEASTBOUND\n\(fullRow)")
        expectRejected("WESTBOUND\n\(fullRow)")
        expectRejected("WESTBOUND EASTBOUND\n\(fullRow)")
        let truncatedRow = fullRow.split(separator: " ").dropLast().joined(separator: " ")
        expectRejected("WESTBOUND\n\(fullRow)\n\(truncatedRow)\nEASTBOUND\n\(fullRow)")
        let times = PATCOSpecialScheduleLoader.normalizedTripTimes(from: skippedRow)!
        precondition(times.count == 14)
        precondition(times[8].isEmpty && times[9].isEmpty && times[11].isEmpty)
        precondition(times[10] == "00:26:00")

        if CommandLine.arguments.count > 1 {
            let pdfData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let schedule = try PATCOSpecialScheduleLoader.parseSpecialSchedulePDF(
                data: pdfData,
                title: title,
                serviceDate: links[0].date,
                sourceURL: links[0].url
            )
            precondition(schedule.trips.contains { $0.stopTimes.contains("") })
            precondition(schedule.trips.contains { !$0.stopTimes.contains("") })

            let feedData = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
            let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: feedData))
            store.applySpecialSchedule(schedule)
            let origin = store.stations.first { $0.name == "Ashland" }!
            let destination = store.stations.first { $0.name == "15/16th and Locust" }!
            let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26))!
            let departures = store.departures(from: origin, to: destination, after: start, limit: 10)
            precondition(!departures.isEmpty)
            precondition(departures.allSatisfy { departure in
                departure.trip.stopTimes.allSatisfy { !$0.arrival.isEmpty && !$0.departure.isEmpty }
            })
            precondition(departures[0].trip.stopTimes.count == 11)
            precondition(!departures[0].trip.stopTimes.contains { $0.stopId == store.stations[8].id })
            let firstTime = calendar.dateComponents([.hour, .minute], from: departures[0].departureDate)
            precondition(firstTime == DateComponents(hour: 0, minute: 4), "First Saturday Ashland departure was \(firstTime)")

            let departuresIncludingRemoved = store.departures(
                from: origin,
                to: destination,
                after: start,
                limit: nil,
                includingRemovedSpecialScheduleDepartures: true
            )
            let activeDepartureTimes = Set(departuresIncludingRemoved.filter { !$0.isRemovedBySpecialSchedule }.map(\.departureDate))
            let removedDepartureTimes = Set(departuresIncludingRemoved.filter(\.isRemovedBySpecialSchedule).map(\.departureDate))
            precondition(
                activeDepartureTimes.isDisjoint(with: removedDepartureTimes),
                "Duplicate active/removed times: \(activeDepartureTimes.intersection(removedDepartureTimes).sorted())"
            )
            let firstPublishedDeparture = departuresIncludingRemoved.first {
                !$0.isRemovedBySpecialSchedule
                    && calendar.dateComponents([.hour, .minute], from: $0.departureDate) == DateComponents(hour: 0, minute: 4)
            }
            precondition(
                firstPublishedDeparture?.scheduleAdjustment?.originalDepartureDate.map {
                    calendar.dateComponents([.hour, .minute], from: $0)
                } == DateComponents(hour: 0, minute: 2),
                "Expected the 12:04 AM special departure to replace the 12:02 AM standard departure."
            )
            precondition(
                !departuresIncludingRemoved.contains {
                    $0.isRemovedBySpecialSchedule
                        && calendar.dateComponents([.hour, .minute], from: $0.departureDate) == DateComponents(hour: 0, minute: 2)
                },
                "The 12:02 AM departure should be adjusted, not listed as removed."
            )
            print("Saturday PDF parsed: \(schedule.trips.count) trips")
        }

        if CommandLine.arguments.count > 2 {
            let page = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            let pageLinks = PATCOSpecialScheduleLoader.specialScheduleLinks(
                from: page,
                baseURL: URL(string: "https://www.ridepatco.org/schedules/schedules.asp")!,
                calendar: calendar
            )
            precondition(pageLinks.contains { $0.url.lastPathComponent == "TW_2026-09-26.pdf" })
        }

        print("Special schedule parsing checks passed")
    }
}
