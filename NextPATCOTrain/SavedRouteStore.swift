import Combine
import Foundation

enum SavedRoutesFeature {
    // Disable the experiment without changing route selection or stored favorites.
    static let isAvailable = true
    static let enabledKey = "savedRoutes.shortcutsEnabled"
}

struct SavedRoute: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let originId: String
    let destinationId: String

    func matches(originId: String?, destinationId: String?) -> Bool {
        self.originId == originId && self.destinationId == destinationId
    }

    func hasChanges(name: String, originId: String, destinationId: String) -> Bool {
        self.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
            || !matches(originId: originId, destinationId: destinationId)
    }

    func reversedDraft() -> SavedRoute {
        SavedRoute(id: UUID(), name: "", originId: destinationId, destinationId: originId)
    }
}

final class SavedRouteStore: ObservableObject {
    private static let storageKey = "savedRoutes.v1"
    private static let defaultsInitializedKey = "savedRoutes.defaultsInitialized.v1"
    private let defaults: UserDefaults
    @Published private(set) var routes: [SavedRoute]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode([SavedRoute].self, from: $0)
        } ?? []
        var ids = Set<UUID>()
        var pairs = Set<[String]>()
        routes = decoded.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.originId.isEmpty && !$0.destinationId.isEmpty
                && $0.originId != $0.destinationId
                && ids.insert($0.id).inserted
                && pairs.insert([$0.originId, $0.destinationId]).inserted
        }
    }

    func initializeDefaultRoutesIfNeeded(stations: [Station]) {
        guard !defaults.bool(forKey: Self.defaultsInitializedKey) else { return }
        // An existing empty collection can represent a deliberate deletion.
        // Never replace it (or corrupt stored data) with starter routes.
        guard defaults.object(forKey: Self.storageKey) == nil, routes.isEmpty else {
            defaults.set(true, forKey: Self.defaultsInitializedKey)
            return
        }
        guard let homeOrigin = stations.first(where: { $0.name == "Lindenwold" }),
              let homeDestination = stations.first(where: { $0.name == "15/16th and Locust" }) else { return }
        routes = [
            SavedRoute(id: UUID(), name: "Home", originId: homeOrigin.id, destinationId: homeDestination.id),
            SavedRoute(id: UUID(), name: "Work", originId: homeDestination.id, destinationId: homeOrigin.id)
        ]
        persist()
        defaults.set(true, forKey: Self.defaultsInitializedKey)
    }

    func savedRoute(originId: String?, destinationId: String?) -> SavedRoute? {
        guard let originId, let destinationId else { return nil }
        return routes.first { $0.matches(originId: originId, destinationId: destinationId) }
    }

    @discardableResult
    func save(name: String, originId: String, destinationId: String) -> Bool {
        let id = savedRoute(originId: originId, destinationId: destinationId)?.id ?? UUID()
        return save(id: id, name: name, originId: originId, destinationId: destinationId)
    }

    @discardableResult
    func save(id: UUID, name: String, originId: String, destinationId: String) -> Bool {
        let name = Self.cleanedName(name)
        guard isNameAvailable(name, excluding: id), !originId.isEmpty, !destinationId.isEmpty,
              originId != destinationId else { return false }
        guard !routes.contains(where: {
            $0.id != id && $0.matches(originId: originId, destinationId: destinationId)
        }) else { return false }
        let updated = SavedRoute(id: id, name: name, originId: originId, destinationId: destinationId)
        if let index = routes.firstIndex(where: { $0.id == id }) {
            routes[index] = updated
        } else {
            routes.append(updated)
        }
        persist()
        return true
    }

    func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let name = Self.cleanedName(name)
        guard !name.isEmpty else { return false }
        return !routes.contains {
            $0.id != id && Self.cleanedName($0.name).compare(
                name, options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
            ) == .orderedSame
        }
    }

    private static func cleanedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func delete(id: UUID) {
        routes.removeAll { $0.id == id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where routes.indices.contains(index) {
            routes.remove(at: index)
        }
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard destination >= 0, destination <= routes.count,
              offsets.allSatisfy({ routes.indices.contains($0) }) else { return }
        let moving = offsets.sorted().map { routes[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) { routes.remove(at: index) }
        routes.insert(contentsOf: moving, at: insertion)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
