import Foundation

@main
struct SavedRoutesCheck {
    static func checkDefaultRoutes() throws {
        let suite = "DefaultSavedRoutesCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf:
            URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let stations = PATCOScheduleStore(feed: feed).stations
        let store = SavedRouteStore(defaults: defaults)
        store.initializeDefaultRoutesIfNeeded(stations: [])
        precondition(store.routes.isEmpty)
        store.initializeDefaultRoutesIfNeeded(stations: stations)
        precondition(store.routes.map(\.name) == ["Home", "Work"])
        let home = store.routes[0]
        let work = store.routes[1]
        precondition(stations.first { $0.id == home.originId }?.name == "Lindenwold")
        precondition(stations.first { $0.id == home.destinationId }?.name == "15/16th and Locust")
        precondition(work.originId == home.destinationId && work.destinationId == home.originId)
        store.initializeDefaultRoutesIfNeeded(stations: stations)
        precondition(store.routes == [home, work])
        precondition(store.save(id: home.id, name: "Personal", originId: home.originId, destinationId: home.destinationId))
        let reopened = SavedRouteStore(defaults: defaults)
        reopened.initializeDefaultRoutesIfNeeded(stations: stations)
        precondition(reopened.routes.map(\.name) == ["Personal", "Work"])
        reopened.delete(at: IndexSet([0, 1]))
        let empty = SavedRouteStore(defaults: defaults)
        empty.initializeDefaultRoutesIfNeeded(stations: stations)
        precondition(empty.routes.isEmpty, "Deleted defaults must never return")

        defaults.removePersistentDomain(forName: suite)
        defaults.set(try JSONEncoder().encode([SavedRoute]()), forKey: "savedRoutes.v1")
        let legacyEmpty = SavedRouteStore(defaults: defaults)
        legacyEmpty.initializeDefaultRoutesIfNeeded(stations: stations)
        precondition(legacyEmpty.routes.isEmpty, "Honor deletions from earlier app versions")

        defaults.removePersistentDomain(forName: suite)
        let custom = SavedRouteStore(defaults: defaults)
        precondition(custom.save(name: "Custom", originId: home.originId, destinationId: home.destinationId))
        custom.initializeDefaultRoutesIfNeeded(stations: stations)
        precondition(custom.routes.map(\.name) == ["Custom"], "Do not add starter routes to existing favorites")
    }

    static func main() throws {
        let view = try String(contentsOfFile: "NextPATCOTrain/SavedRoutesView.swift", encoding: .utf8)
        precondition(view.contains("Label(\"Add Route\", systemImage: \"plus\")"))
        precondition(view.contains(".accessibilityLabel(\"Add Route\")"))
        precondition(view.contains("originId: originId, destinationId: destinationId)"))
        precondition(!view.contains("let route = store.savedRoute(originId: route.originId, destinationId: route.destinationId) ?? route"),
                     "Adding a route must not silently switch into editing an existing route")
        try checkDefaultRoutes()
        let suite = "SavedRoutesCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untouched", forKey: "selectedRoute")
        let store = SavedRouteStore(defaults: defaults)
        precondition(store.routes.isEmpty)
        precondition(!store.save(name: "  ", originId: "2", destinationId: "14"))
        precondition(!store.save(name: "Work", originId: "2", destinationId: "2"))
        precondition(!store.save(name: "Work", originId: "", destinationId: "14"))
        precondition(store.save(name: "  Work  ", originId: "2", destinationId: "14"))
        let firstID = store.routes[0].id
        precondition(store.routes[0].name == "Work")
        let originalRoute = store.routes[0]
        let reverseDraft = originalRoute.reversedDraft()
        precondition(reverseDraft.id != originalRoute.id)
        precondition(reverseDraft.name.isEmpty, "Reverse routes must not be named automatically")
        precondition(reverseDraft.originId == originalRoute.destinationId)
        precondition(reverseDraft.destinationId == originalRoute.originId)
        precondition(store.routes.count == 1, "Offering a reverse route must not save it automatically")
        precondition(!store.save(id: reverseDraft.id, name: reverseDraft.name,
                                 originId: reverseDraft.originId, destinationId: reverseDraft.destinationId))
        precondition(store.routes.count == 1, "Canceling or leaving an unnamed reverse draft must preserve the first route only")
        precondition(!originalRoute.hasChanges(name: "Work", originId: "2", destinationId: "14"))
        precondition(!originalRoute.hasChanges(name: " Work \n", originId: "2", destinationId: "14"))
        precondition(originalRoute.hasChanges(name: "Office", originId: "2", destinationId: "14"))
        precondition(originalRoute.hasChanges(name: "work", originId: "2", destinationId: "14"))
        precondition(originalRoute.hasChanges(name: "Work", originId: "3", destinationId: "14"))
        precondition(originalRoute.hasChanges(name: "Work", originId: "2", destinationId: "13"))
        precondition(originalRoute.hasChanges(name: "Work", originId: "14", destinationId: "2"))
        precondition(store.save(name: "Office", originId: "2", destinationId: "14"))
        precondition(store.routes.count == 1 && store.routes[0].id == firstID)
        precondition(store.save(name: "Home", originId: "14", destinationId: "2"))
        precondition(store.savedRoute(originId: "2", destinationId: "14")?.id == firstID)
        precondition(store.savedRoute(originId: "2", destinationId: "14")?.name == "Office")
        precondition(store.savedRoute(originId: "14", destinationId: "2")?.name == "Home")
        precondition(store.savedRoute(originId: "3", destinationId: "14") == nil)
        precondition(store.savedRoute(originId: nil, destinationId: "14") == nil)
        precondition(store.savedRoute(originId: "2", destinationId: nil) == nil)
        precondition(!store.isNameAvailable(" home \n"))
        precondition(store.isNameAvailable(" office ", excluding: firstID))
        precondition(!store.save(name: "HOME", originId: "5", destinationId: "14"))
        precondition(!store.save(id: firstID, name: " Home ", originId: "2", destinationId: "14"))
        precondition(store.routes[0].name == "Office")
        precondition(store.save(id: firstID, name: "Office", originId: "2", destinationId: "14"))
        precondition(store.isNameAvailable("Work"))
        precondition(store.save(name: "Weekend", originId: "3", destinationId: "14"))
        precondition(store.save(name: "Other", originId: "4", destinationId: "14"))
        precondition(store.routes[0].matches(originId: "2", destinationId: "14"))
        precondition(!store.routes[0].matches(originId: "14", destinationId: "2"))
        precondition(!store.routes[0].matches(originId: nil, destinationId: nil))
        store.move(from: [0, 2], to: 4)
        precondition(store.routes.map(\.name) == ["Home", "Other", "Office", "Weekend"])
        store.move(from: [3], to: 0)
        precondition(store.routes.map(\.name) == ["Weekend", "Home", "Other", "Office"])
        store.delete(at: [1, 2])
        precondition(store.routes.map(\.name) == ["Weekend", "Office"])
        defaults.set(false, forKey: SavedRoutesFeature.enabledKey)
        let reopened = SavedRouteStore(defaults: defaults)
        precondition(reopened.routes == store.routes, "Hiding the feature must preserve saved routes")
        precondition(defaults.string(forKey: "selectedRoute") == "untouched")
        precondition(reopened.save(name: String(repeating: "a", count: 40), originId: "2", destinationId: "14"))
        precondition(reopened.routes[1].name.count == 24)
        defaults.set(Data("invalid".utf8), forKey: "savedRoutes.v1")
        precondition(SavedRouteStore(defaults: defaults).routes.isEmpty)
        let invalid = [SavedRoute(id: UUID(), name: "Invalid", originId: "2", destinationId: "2"),
                       SavedRoute(id: firstID, name: "Work", originId: "2", destinationId: "14"),
                       SavedRoute(id: UUID(), name: "Duplicate", originId: "2", destinationId: "14")]
        defaults.set(try JSONEncoder().encode(invalid), forKey: "savedRoutes.v1")
        precondition(SavedRouteStore(defaults: defaults).routes.count == 1)
        let editingStore = SavedRouteStore(defaults: defaults)
        precondition(editingStore.save(name: "Home", originId: "14", destinationId: "2"))
        let homeID = editingStore.routes[1].id
        precondition(!editingStore.save(id: firstID, name: "Conflict", originId: "14", destinationId: "2"))
        precondition(editingStore.routes[0].name == "Work")
        precondition(editingStore.save(id: firstID, name: "Office", originId: "3", destinationId: "14"))
        precondition(editingStore.routes.count == 2 && editingStore.routes[0].id == firstID)
        precondition(editingStore.routes[0].originId == "3")
        precondition(editingStore.savedRoute(originId: "3", destinationId: "14")?.id == firstID)
        precondition(editingStore.savedRoute(originId: "2", destinationId: "14") == nil)
        precondition(editingStore.routes[1].id == homeID)
        precondition(SavedRouteStore(defaults: defaults).routes == editingStore.routes)
        editingStore.move(from: [0], to: 2)
        editingStore.delete(id: firstID)
        precondition(editingStore.savedRoute(originId: "3", destinationId: "14") == nil)
        precondition(editingStore.routes.map(\.id) == [homeID], "Delete must use identity, not row position")
        precondition(defaults.string(forKey: "selectedRoute") == "untouched")
        precondition(SavedRouteStore(defaults: defaults).routes.map(\.id) == [homeID])
        editingStore.delete(id: homeID)
        precondition(SavedRouteStore(defaults: defaults).routes.isEmpty)
        let legacyDuplicates = [
            SavedRoute(id: UUID(), name: "Home", originId: "2", destinationId: "14"),
            SavedRoute(id: UUID(), name: "home", originId: "14", destinationId: "2")
        ]
        defaults.set(try JSONEncoder().encode(legacyDuplicates), forKey: "savedRoutes.v1")
        let legacyStore = SavedRouteStore(defaults: defaults)
        precondition(legacyStore.routes == legacyDuplicates, "Existing duplicate names must not lose saved routes")
        precondition(!legacyStore.isNameAvailable("Home", excluding: legacyDuplicates[0].id))
        precondition(legacyStore.save(id: legacyDuplicates[0].id, name: "Work", originId: "2", destinationId: "14"))
        precondition(legacyStore.isNameAvailable("Home", excluding: legacyDuplicates[1].id))
        let editorSource = try String(contentsOfFile: "NextPATCOTrain/SavedRoutesView.swift", encoding: .utf8)
        precondition(editorSource.contains("Text(\"Already saved as \\(duplicateRoute.name).\")"))
        precondition(editorSource.contains("Label(\"Edit\", systemImage: \"pencil\")"))
        precondition(!editorSource.contains("Label(\"Edit saved route\""))
        precondition(editorSource.contains("} else if let validationMessage {"))
        precondition(editorSource.contains("route = duplicateRoute"))
        print("Saved routes checks passed: persistence, duplicates, direction, rename, reorder, delete, isolation, disabled feature and corrupt data")
    }
}
