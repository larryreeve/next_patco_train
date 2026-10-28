import Foundation

@main
struct UXRecoveryCheck {
    @MainActor
    static func main() async throws {
        var fail = false
        var empty = false
        let provider = PATCOAlertProvider { request in
            if fail { throw URLError(.notConnectedToInternet) }
            let html = empty ? "<ul></ul>" : "<ul>" + (1...5).map {
                "<li>Service Advisory: Test notice \($0)</li>"
            }.joined() + "</ul>"
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await provider.refreshNow(force: true)
        precondition(provider.alerts.count == 5)
        let cached = provider.alerts
        let updated = provider.lastUpdated
        fail = true
        await provider.refreshNow(force: true)
        precondition(provider.alerts == cached && provider.lastUpdated == updated)
        precondition(provider.errorMessage != nil && !provider.isLoading)
        fail = false
        empty = true
        await provider.refreshNow(force: true)
        precondition(provider.alerts.isEmpty && provider.errorMessage == nil)
        let unavailable = PATCOAlertProvider { _ in throw URLError(.notConnectedToInternet) }
        await unavailable.refreshNow()
        precondition(unavailable.alerts.isEmpty && unavailable.errorMessage != nil)

        var requests = 0
        var offline = true
        let retrying = PATCOAlertProvider { request in
            requests += 1
            if offline { throw URLError(.notConnectedToInternet) }
            return (Data("<ul></ul>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var attempt = Date()
        for minutes in [2, 4, 8, 16, 30, 30] {
            await retrying.refreshNow(now: attempt)
            let count = requests
            let next = attempt.addingTimeInterval(Double(minutes * 60))
            precondition(retrying.nextAutomaticAttempt == next)
            await retrying.refreshNow(now: next.addingTimeInterval(-1))
            precondition(requests == count, "Automatic checks must honor backoff")
            attempt = next
        }
        offline = false
        await retrying.refreshNow(force: true, now: attempt.addingTimeInterval(-60))
        precondition(retrying.errorMessage == nil)
        offline = true
        await retrying.refreshNow(force: true, now: attempt)
        precondition(retrying.nextAutomaticAttempt == attempt.addingTimeInterval(120),
                     "Successful recovery must reset backoff")

        let iso = ISO8601DateFormatter()
        let tonight = iso.date(from: "2026-10-18T03:50:00Z")!
        let tomorrow = iso.date(from: "2026-10-18T04:15:00Z")!
        precondition(PATCOClock.accessibleTimeText(tonight, now: tonight).hasPrefix("Today,"))
        precondition(PATCOClock.accessibleTimeText(tomorrow, now: tonight).hasPrefix("Tomorrow,"))
        precondition(PATCOClock.accessibleTimeText(tomorrow, now: tomorrow).hasPrefix("Today,"))
        let later = PATCOClock.accessibleTimeText(tomorrow.addingTimeInterval(86400), now: tonight)
        precondition(!later.hasPrefix("Today") && !later.hasPrefix("Tomorrow"))
        let edt = iso.date(from: "2026-11-01T05:30:00Z")!
        let est = iso.date(from: "2026-11-01T06:30:00Z")!
        precondition(PATCOClock.accessibleTimeText(edt, now: edt, relativeTo: est).contains("EDT"))
        precondition(PATCOClock.accessibleTimeText(est, now: edt, relativeTo: edt).contains("EST"))

        let route = SavedRoute(id: UUID(), name: "Work", originId: "2", destinationId: "14")
        precondition(!route.hasChanges(name: "Work", originId: "2", destinationId: "14"))
        precondition(route.hasChanges(name: "Office", originId: "2", destinationId: "14"))
        precondition(route.hasChanges(name: "Work", originId: "1", destinationId: "14"))
        precondition(route.hasChanges(name: "", originId: "2", destinationId: "14"))
        let content = try String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        precondition(content.contains("if !visibleAlerts.isEmpty {"))
        precondition(!content.contains("Service alerts could not be checked."))
        precondition(!content.contains("if let error = alertProvider.errorMessage"))
        precondition(content.contains("ForEach(alerts)"))
        precondition(!content.contains("alerts.prefix(3)"))
        let row = try String(contentsOfFile: "NextPATCOTrain/DepartureListView.swift", encoding: .utf8)
        precondition(row.contains("PATCOClock.accessibleTimeText(departure.departureDate"))
        precondition(row.contains("PATCOClock.accessibleTimeText(departure.arrivalDate"))
        let editor = try String(contentsOfFile: "NextPATCOTrain/SavedRoutesView.swift", encoding: .utf8)
        precondition(editor.contains(".interactiveDismissDisabled(hasUnsavedChanges)"))
        precondition(editor.contains("if hasUnsavedChanges { showsDiscardConfirmation = true }"))
        precondition(editor.contains("Button(\"Keep editing\", role: .cancel)"))
        print("UX recovery checks passed: cached alerts, offline state, retry, all alerts, spoken dates/DST, unsaved edits")
    }
}
