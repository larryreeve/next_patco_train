import SwiftUI

struct SavedRouteShortcuts: View {
    @ObservedObject var store: SavedRouteStore
    let stations: [Station]
    let originId: String?
    let destinationId: String?
    let onSelect: (SavedRoute) -> Void
    @State private var showsManager = false
    @State private var editingRoute: SavedRoute?
    @ScaledMetric(relativeTo: .subheadline) private var shortcutHeight = 44.0

    private var currentSavedRoute: SavedRoute? {
        store.savedRoute(originId: originId, destinationId: destinationId)
    }

    private var availableRoutes: [SavedRoute] {
        store.routes.filter { route in
            stations.contains { $0.id == route.originId }
                && stations.contains { $0.id == route.destinationId }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if availableRoutes.isEmpty {
                currentRouteAction
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(availableRoutes) { route in
                            let selected = route.matches(originId: originId, destinationId: destinationId)
                            Button { onSelect(route) } label: {
                                Label(route.name, systemImage: selected ? "bookmark.fill" : "bookmark")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(selected ? Color.patcoGold : .white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 140, alignment: .leading)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        selected ? Color.patcoGold.opacity(0.10) : Color.white.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(selected ? Color.patcoGold : Color.white.opacity(0.35), lineWidth: 1)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("\(route.name), \(stationName(route.originId)) to \(stationName(route.destinationId))")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help("\(route.name): \(stationName(route.originId)) to \(stationName(route.destinationId))")
                        }
                        manageRoutesButton
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: shortcutHeight)
            }
            if availableRoutes.isEmpty {
                manageRoutesButton
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-previewSavedRoutes") {
                showsManager = true
            }
        }
        #endif
        .sheet(isPresented: $showsManager) {
            SavedRoutesManager(store: store, stations: stations,
                               originId: originId, destinationId: destinationId)
        }
        .sheet(item: $editingRoute) { route in
            SavedRouteEditor(route: route, store: store, stations: stations)
        }
    }

    private var manageRoutesButton: some View {
        Button {
            showsManager = true
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Manage saved routes")
        .help("Manage saved routes")
    }

    private var currentRouteAction: some View {
        Button {
            guard let originId, let destinationId else { return }
            editingRoute = currentSavedRoute
                ?? SavedRoute(id: UUID(), name: "", originId: originId, destinationId: destinationId)
        } label: {
            Label(currentSavedRoute.map { "Edit \($0.name) route" } ?? "Save route",
                  systemImage: currentSavedRoute == nil ? "bookmark" : "pencil")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(originId == nil || destinationId == nil || originId == destinationId)
    }

    private func stationName(_ id: String) -> String {
        stations.first { $0.id == id }?.name ?? "Unavailable station"
    }
}

private struct SavedRoutesManager: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: SavedRouteStore
    let stations: [Station]
    let originId: String?
    let destinationId: String?
    @State private var editingRoute: SavedRoute?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.routes.isEmpty {
                        Text("No saved routes").foregroundStyle(.secondary)
                        Button(action: addRoute) {
                            Label("Add Route", systemImage: "plus")
                        }
                        .disabled(stations.count < 2)
                    }
                    ForEach(store.routes) { route in
                        Group {
                            if editMode.isEditing {
                                routeRow(route)
                            } else {
                                Button { editingRoute = route } label: {
                                    routeRow(route)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Edit \(route.name), \(station(route.originId)?.name ?? "Unavailable station") to \(station(route.destinationId)?.name ?? "Unavailable station")")
                                .help("Edit \(route.name)")
                            }
                        }
                        .contextMenu {
                            if let index = store.routes.firstIndex(where: { $0.id == route.id }) {
                                Button {
                                    store.move(from: IndexSet(integer: index), to: index - 1)
                                } label: { Label("Move up", systemImage: "arrow.up") }
                                .disabled(index == 0)
                                Button {
                                    store.move(from: IndexSet(integer: index), to: index + 2)
                                } label: { Label("Move down", systemImage: "arrow.down") }
                                .disabled(index == store.routes.count - 1)
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        store.move(from: offsets, to: destination)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 12, for: .scrollContent)
            .environment(\.editMode, $editMode)
            .tint(.primary)
            .navigationTitle("Saved routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    } label: {
                        Text(editMode.isEditing ? "Done" : "Reorder")
                            .font(.body)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 78, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(store.routes.count < 2 && !editMode.isEditing)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: addRoute) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Route")
                    .help("Add Route")
                    .disabled(stations.count < 2)
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close saved routes")
                }
            }
            .onChange(of: store.routes.count) { _, count in
                if count < 2 { editMode = .inactive }
            }
            .sheet(item: $editingRoute) { route in
                SavedRouteEditor(route: route, store: store, stations: stations)
            }
            #if DEBUG && targetEnvironment(simulator)
            .task {
                if ProcessInfo.processInfo.arguments.contains("-previewAddRoute") {
                    addRoute()
                }
            }
            #endif
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private func station(_ id: String) -> Station? { stations.first { $0.id == id } }

    private func addRoute() {
        guard let origin = stations.first(where: { $0.id == originId }) ?? stations.first,
              let destination = stations.first(where: { $0.id == destinationId && $0.id != origin.id })
                ?? stations.first(where: { $0.id != origin.id }) else { return }
        editMode = .inactive
        editingRoute = SavedRoute(id: UUID(), name: "", originId: origin.id, destinationId: destination.id)
    }

    private func routeRow(_ route: SavedRoute) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(station(route.originId)?.name ?? "Unavailable station") to \(station(route.destinationId)?.name ?? "Unavailable station")")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !editMode.isEditing {
                Image(systemName: "pencil")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct SavedRouteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var route: SavedRoute
    @ObservedObject var store: SavedRouteStore
    let stations: [Station]
    @State private var name: String
    @State private var originId: String
    @State private var destinationId: String
    @State private var showsDeleteConfirmation = false
    @State private var showsReverseRouteOffer = false
    @State private var showsDiscardConfirmation = false
    @FocusState private var nameIsFocused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldLabelWidth = 64.0

    init(route: SavedRoute, store: SavedRouteStore, stations: [Station]) {
        _route = State(initialValue: route)
        self.store = store
        self.stations = stations
        _name = State(initialValue: route.name)
        _originId = State(initialValue: route.originId)
        _destinationId = State(initialValue: route.destinationId)
    }

    private var isExisting: Bool { store.routes.contains { $0.id == route.id } }

    private var hasUnsavedChanges: Bool {
        route.hasChanges(name: name, originId: originId, destinationId: destinationId)
    }

    private var nameValidationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return store.isNameAvailable(name, excluding: route.id) ? nil : "This name is already used. Choose a different name."
    }

    private var suggestedNames: [String] {
        ["Home", "Work"].filter { store.isNameAvailable($0) }
    }

    private var duplicateRoute: SavedRoute? {
        store.routes.first {
            $0.id != route.id && $0.matches(originId: originId, destinationId: destinationId)
        }
    }

    private var validationMessage: String? {
        if originId == destinationId { return "Choose different departure and destination stations." }
        if !stations.contains(where: { $0.id == originId }) || !stations.contains(where: { $0.id == destinationId }) {
            return "Choose available stations."
        }
        if let duplicateRoute {
            return "Route already saved as \(duplicateRoute.name)."
        }
        return nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && nameValidationMessage == nil && validationMessage == nil
            && (!isExisting || route.hasChanges(name: name, originId: originId, destinationId: destinationId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    routeNameField
                    if let nameValidationMessage {
                        Text(nameValidationMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !isExisting && !suggestedNames.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { nameSuggestions }
                            VStack(alignment: .leading, spacing: 8) { nameSuggestions }
                        }
                    }
                    stationPicker("From", selection: $originId)
                    stationPicker("To", selection: $destinationId)
                    if let duplicateRoute {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Already saved as \(duplicateRoute.name).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                nameIsFocused = false
                                route = duplicateRoute
                                name = duplicateRoute.name
                                originId = duplicateRoute.originId
                                destinationId = duplicateRoute.destinationId
                            } label: {
                                Label("Edit", systemImage: "pencil")
                                    .labelStyle(.titleAndIcon)
                                    .font(.footnote.weight(.semibold))
                                    .fixedSize()
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .tint(.blue)
                            .accessibilityLabel("Edit saved route \(duplicateRoute.name)")
                        }
                    } else if let validationMessage {
                        Text(validationMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if isExisting {
                    Section {
                        Button(role: .destructive) { showsDeleteConfirmation = true } label: {
                            Label("Delete route", systemImage: "trash")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .navigationTitle(isExisting ? "Edit route" : "Add Route")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges { showsDiscardConfirmation = true }
                        else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .alert("Delete \"\(route.name)\"?", isPresented: $showsDeleteConfirmation) {
                Button("Delete route", role: .destructive) {
                    store.delete(id: route.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved route.")
            }
            .alert("Route saved", isPresented: $showsReverseRouteOffer) {
                Button("Save reverse route", action: prepareReverseRoute)
                Button("Done", role: .cancel) { dismiss() }
            } message: {
                Text("Save the reverse route too?")
            }
            .onAppear { nameIsFocused = !isExisting }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog("Discard unsaved changes?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var routeNameField: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            fieldLabel("Name")
                .accessibilityHidden(true)
            TextField("Route name", text: $name)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .frame(minWidth: 120, maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(nameIsFocused ? Color.blue.opacity(0.7) : Color.primary.opacity(0.25), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .focused($nameIsFocused)
                .tint(.blue)
                .submitLabel(.done)
                .onSubmit(save)
                .onChange(of: name) { _, value in name = String(value.prefix(24)) }
                .accessibilityLabel("Route name")
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : fieldLabelWidth, alignment: .leading)
    }

    private var nameSuggestions: some View {
        ForEach(suggestedNames, id: \.self) { suggestion in
            Button { name = suggestion } label: {
                Label(suggestion, systemImage: suggestion == "Home" ? "house" : "briefcase")
                    .labelStyle(.titleAndIcon)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderless)
            .tint(.blue)
            .accessibilityLabel("Name route \(suggestion)")
        }
    }

    private func stationPicker(_ title: String, selection: Binding<String>) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        let stationName = stations.first { $0.id == selection.wrappedValue }?.name ?? "Unavailable station"
        return Menu {
            Picker(title, selection: selection) {
                if !stations.contains(where: { $0.id == selection.wrappedValue }) {
                    Text("Unavailable station").tag(selection.wrappedValue)
                        .disabled(true)
                }
                ForEach(stations) { station in
                    Text(station.name).tag(station.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            layout {
                fieldLabel(title)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stationName)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(stationName)")
        .accessibilityHint("Choose a station")
    }

    private func save() {
        guard canSave else { return }
        let isFirstRoute = store.routes.isEmpty
        if store.save(id: route.id, name: name, originId: originId, destinationId: destinationId) {
            if isFirstRoute, let savedRoute = store.savedRoute(originId: originId, destinationId: destinationId) {
                route = savedRoute
                name = savedRoute.name
                nameIsFocused = false
                showsReverseRouteOffer = true
            } else {
                dismiss()
            }
        }
    }

    private func prepareReverseRoute() {
        let reverse = store.savedRoute(originId: route.destinationId, destinationId: route.originId)
            ?? route.reversedDraft()
        route = reverse
        name = reverse.name
        originId = reverse.originId
        destinationId = reverse.destinationId
        nameIsFocused = !isExisting
    }
}
