#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import Observation

struct SavedRoutesCheck {
    static func checkDefaultRoutes() throws {
        let suite = "DefaultSavedRoutesCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf:
            URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let stations = PATCOScheduleStore(feed: feed).stations
        let store = SavedRouteStore(defaults: defaults)
        XCTAssertTrue(store.shortcutsEnabled)
        let preferenceUpdates = ObservationCounter()
        func observePreference() {
            withObservationTracking { _ = store.shortcutsEnabled } onChange: { preferenceUpdates.increment() }
        }
        observePreference()
        for _ in 0..<100 {
            _ = store.shortcutsEnabled
            store.setShortcutsEnabled(true)
        }
        XCTAssertTrue(preferenceUpdates.value == 0, "Reading or reapplying a setting must not trigger a redraw loop")
        store.setShortcutsEnabled(false)
        XCTAssertTrue(preferenceUpdates.value == 1 && !SavedRouteStore(defaults: defaults).shortcutsEnabled)
        observePreference()
        store.setShortcutsEnabled(true)
        XCTAssertTrue(preferenceUpdates.value == 2 && SavedRouteStore(defaults: defaults).shortcutsEnabled)
        store.initializeDefaultRoutesIfNeeded(stations: [])
        XCTAssertTrue(store.routes.isEmpty)
        store.initializeDefaultRoutesIfNeeded(stations: stations)
        XCTAssertTrue(store.routes.map(\.name) == ["Home", "Work"])
        let home = store.routes[0]
        let work = store.routes[1]
        XCTAssertTrue(stations.first { $0.id == home.originId }?.name == "Lindenwold")
        XCTAssertTrue(stations.first { $0.id == home.destinationId }?.name == "15/16th and Locust")
        XCTAssertTrue(work.originId == home.destinationId && work.destinationId == home.originId)
        store.initializeDefaultRoutesIfNeeded(stations: stations)
        XCTAssertTrue(store.routes == [home, work])
        XCTAssertTrue(store.save(id: home.id, name: "Personal", originId: home.originId, destinationId: home.destinationId))
        let reopened = SavedRouteStore(defaults: defaults)
        reopened.initializeDefaultRoutesIfNeeded(stations: stations)
        XCTAssertTrue(reopened.routes.map(\.name) == ["Personal", "Work"])
        reopened.delete(at: IndexSet([0, 1]))
        let empty = SavedRouteStore(defaults: defaults)
        empty.initializeDefaultRoutesIfNeeded(stations: stations)
        XCTAssertTrue(empty.routes.isEmpty, "Deleted defaults must never return")

        defaults.removePersistentDomain(forName: suite)
        defaults.set(try JSONEncoder().encode([SavedRoute]()), forKey: "savedRoutes.v1")
        let legacyEmpty = SavedRouteStore(defaults: defaults)
        legacyEmpty.initializeDefaultRoutesIfNeeded(stations: stations)
        XCTAssertTrue(legacyEmpty.routes.isEmpty, "Honor deletions from earlier app versions")

        defaults.removePersistentDomain(forName: suite)
        let custom = SavedRouteStore(defaults: defaults)
        XCTAssertTrue(custom.save(name: "Custom", originId: home.originId, destinationId: home.destinationId))
        custom.initializeDefaultRoutesIfNeeded(stations: stations)
        XCTAssertTrue(custom.routes.map(\.name) == ["Custom"], "Do not add starter routes to existing favorites")
    }

    static func run() throws {
        let view = try String(contentsOfFile: "NextPATCOTrain/SavedRoutesView.swift", encoding: .utf8)
        XCTAssertTrue(view.contains("Label(\"Add Route\", systemImage: \"plus\")"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"Add Route\")"))
        XCTAssertTrue(view.contains("originId: originId, destinationId: destinationId)"))
        XCTAssertTrue(!view.contains("let route = store.savedRoute(originId: route.originId, destinationId: route.destinationId) ?? route"),
                     "Adding a route must not silently switch into editing an existing route")
        try checkDefaultRoutes()
        let suite = "SavedRoutesCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untouched", forKey: "selectedRoute")
        let store = SavedRouteStore(defaults: defaults)
        XCTAssertTrue(store.routes.isEmpty)
        XCTAssertTrue(!store.save(name: "  ", originId: "2", destinationId: "14"))
        XCTAssertTrue(!store.save(name: "Work", originId: "2", destinationId: "2"))
        XCTAssertTrue(!store.save(name: "Work", originId: "", destinationId: "14"))
        XCTAssertTrue(store.save(name: "  Work  ", originId: "2", destinationId: "14"))
        let firstID = store.routes[0].id
        XCTAssertTrue(store.routes[0].name == "Work")
        let originalRoute = store.routes[0]
        let reverseDraft = originalRoute.reversedDraft()
        XCTAssertTrue(reverseDraft.id != originalRoute.id)
        XCTAssertTrue(reverseDraft.name.isEmpty, "Reverse routes must not be named automatically")
        XCTAssertTrue(reverseDraft.originId == originalRoute.destinationId)
        XCTAssertTrue(reverseDraft.destinationId == originalRoute.originId)
        XCTAssertTrue(store.routes.count == 1, "Offering a reverse route must not save it automatically")
        XCTAssertTrue(!store.save(id: reverseDraft.id, name: reverseDraft.name,
                                 originId: reverseDraft.originId, destinationId: reverseDraft.destinationId))
        XCTAssertTrue(store.routes.count == 1, "Canceling or leaving an unnamed reverse draft must preserve the first route only")
        XCTAssertTrue(!originalRoute.hasChanges(name: "Work", originId: "2", destinationId: "14"))
        XCTAssertTrue(!originalRoute.hasChanges(name: " Work \n", originId: "2", destinationId: "14"))
        XCTAssertTrue(originalRoute.hasChanges(name: "Office", originId: "2", destinationId: "14"))
        XCTAssertTrue(originalRoute.hasChanges(name: "work", originId: "2", destinationId: "14"))
        XCTAssertTrue(originalRoute.hasChanges(name: "Work", originId: "3", destinationId: "14"))
        XCTAssertTrue(originalRoute.hasChanges(name: "Work", originId: "2", destinationId: "13"))
        XCTAssertTrue(originalRoute.hasChanges(name: "Work", originId: "14", destinationId: "2"))
        XCTAssertTrue(store.save(name: "Office", originId: "2", destinationId: "14"))
        XCTAssertTrue(store.routes.count == 1 && store.routes[0].id == firstID)
        XCTAssertTrue(store.save(name: "Home", originId: "14", destinationId: "2"))
        XCTAssertTrue(store.savedRoute(originId: "2", destinationId: "14")?.id == firstID)
        XCTAssertTrue(store.savedRoute(originId: "2", destinationId: "14")?.name == "Office")
        XCTAssertTrue(store.savedRoute(originId: "14", destinationId: "2")?.name == "Home")
        XCTAssertTrue(store.savedRoute(originId: "3", destinationId: "14") == nil)
        XCTAssertTrue(store.savedRoute(originId: nil, destinationId: "14") == nil)
        XCTAssertTrue(store.savedRoute(originId: "2", destinationId: nil) == nil)
        XCTAssertTrue(!store.isNameAvailable(" home \n"))
        XCTAssertTrue(store.isNameAvailable(" office ", excluding: firstID))
        XCTAssertTrue(!store.save(name: "HOME", originId: "5", destinationId: "14"))
        XCTAssertTrue(!store.save(id: firstID, name: " Home ", originId: "2", destinationId: "14"))
        XCTAssertTrue(store.routes[0].name == "Office")
        XCTAssertTrue(store.save(id: firstID, name: "Office", originId: "2", destinationId: "14"))
        XCTAssertTrue(store.isNameAvailable("Work"))
        XCTAssertTrue(store.save(name: "Weekend", originId: "3", destinationId: "14"))
        XCTAssertTrue(store.save(name: "Other", originId: "4", destinationId: "14"))
        XCTAssertTrue(store.routes[0].matches(originId: "2", destinationId: "14"))
        XCTAssertTrue(!store.routes[0].matches(originId: "14", destinationId: "2"))
        XCTAssertTrue(!store.routes[0].matches(originId: nil, destinationId: nil))
        store.move(from: [0, 2], to: 4)
        XCTAssertTrue(store.routes.map(\.name) == ["Home", "Other", "Office", "Weekend"])
        store.move(from: [3], to: 0)
        XCTAssertTrue(store.routes.map(\.name) == ["Weekend", "Home", "Other", "Office"])
        store.delete(at: [1, 2])
        XCTAssertTrue(store.routes.map(\.name) == ["Weekend", "Office"])
        defaults.set(false, forKey: SavedRoutesFeature.enabledKey)
        let reopened = SavedRouteStore(defaults: defaults)
        XCTAssertTrue(reopened.routes == store.routes, "Hiding the feature must preserve saved routes")
        XCTAssertTrue(defaults.string(forKey: "selectedRoute") == "untouched")
        XCTAssertTrue(reopened.save(name: String(repeating: "a", count: 40), originId: "2", destinationId: "14"))
        XCTAssertTrue(reopened.routes[1].name.count == 24)
        defaults.set(Data("invalid".utf8), forKey: "savedRoutes.v1")
        XCTAssertTrue(SavedRouteStore(defaults: defaults).routes.isEmpty)
        let invalid = [SavedRoute(id: UUID(), name: "Invalid", originId: "2", destinationId: "2"),
                       SavedRoute(id: firstID, name: "Work", originId: "2", destinationId: "14"),
                       SavedRoute(id: UUID(), name: "Duplicate", originId: "2", destinationId: "14")]
        defaults.set(try JSONEncoder().encode(invalid), forKey: "savedRoutes.v1")
        XCTAssertTrue(SavedRouteStore(defaults: defaults).routes.count == 1)
        let editingStore = SavedRouteStore(defaults: defaults)
        XCTAssertTrue(editingStore.save(name: "Home", originId: "14", destinationId: "2"))
        let homeID = editingStore.routes[1].id
        XCTAssertTrue(!editingStore.save(id: firstID, name: "Conflict", originId: "14", destinationId: "2"))
        XCTAssertTrue(editingStore.routes[0].name == "Work")
        XCTAssertTrue(editingStore.save(id: firstID, name: "Office", originId: "3", destinationId: "14"))
        XCTAssertTrue(editingStore.routes.count == 2 && editingStore.routes[0].id == firstID)
        XCTAssertTrue(editingStore.routes[0].originId == "3")
        XCTAssertTrue(editingStore.savedRoute(originId: "3", destinationId: "14")?.id == firstID)
        XCTAssertTrue(editingStore.savedRoute(originId: "2", destinationId: "14") == nil)
        XCTAssertTrue(editingStore.routes[1].id == homeID)
        XCTAssertTrue(SavedRouteStore(defaults: defaults).routes == editingStore.routes)
        editingStore.move(from: [0], to: 2)
        editingStore.delete(id: firstID)
        XCTAssertTrue(editingStore.savedRoute(originId: "3", destinationId: "14") == nil)
        XCTAssertTrue(editingStore.routes.map(\.id) == [homeID], "Delete must use identity, not row position")
        XCTAssertTrue(defaults.string(forKey: "selectedRoute") == "untouched")
        XCTAssertTrue(SavedRouteStore(defaults: defaults).routes.map(\.id) == [homeID])
        editingStore.delete(id: homeID)
        XCTAssertTrue(SavedRouteStore(defaults: defaults).routes.isEmpty)
        let legacyDuplicates = [
            SavedRoute(id: UUID(), name: "Home", originId: "2", destinationId: "14"),
            SavedRoute(id: UUID(), name: "home", originId: "14", destinationId: "2")
        ]
        defaults.set(try JSONEncoder().encode(legacyDuplicates), forKey: "savedRoutes.v1")
        let legacyStore = SavedRouteStore(defaults: defaults)
        XCTAssertTrue(legacyStore.routes == legacyDuplicates, "Existing duplicate names must not lose saved routes")
        XCTAssertTrue(!legacyStore.isNameAvailable("Home", excluding: legacyDuplicates[0].id))
        XCTAssertTrue(legacyStore.save(id: legacyDuplicates[0].id, name: "Work", originId: "2", destinationId: "14"))
        XCTAssertTrue(legacyStore.isNameAvailable("Home", excluding: legacyDuplicates[1].id))
        let editorSource = try String(contentsOfFile: "NextPATCOTrain/SavedRoutesView.swift", encoding: .utf8)
        XCTAssertTrue(editorSource.contains("Text(\"Already saved as \\(duplicateRoute.name).\")"))
        XCTAssertTrue(editorSource.contains("Label(\"Edit\", systemImage: \"pencil\")"))
        XCTAssertTrue(!editorSource.contains("Label(\"Edit saved route\""))
        XCTAssertTrue(editorSource.contains("} else if let validationMessage {"))
        XCTAssertTrue(editorSource.contains("route = duplicateRoute"))
        print("Saved routes checks passed: persistence, duplicates, direction, rename, reorder, delete, isolation, disabled feature and corrupt data")
    }
}
