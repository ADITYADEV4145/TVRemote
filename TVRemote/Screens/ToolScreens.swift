import SwiftUI
import TVRemoteKit

struct KeyboardScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @Environment(\.isDesignPreview) private var isDesignPreview
    @State private var previewQuery = ""
    @FocusState private var focused: Bool
    @State private var sending = false
    var sentPreview = false

    private var query: Binding<String> {
        isDesignPreview ? $previewQuery : Binding { connection.keyboardDraft } set: { connection.keyboardDraft = $0 }
    }
    private var isSearch: Bool { isDesignPreview || connection.supportsSearch }
    private var isTyping: Bool { connection.supportsTyping }
    private var canSend: Bool { connection.canControl && (isTyping || isSearch) }
    private var sendLabel: String { isTyping ? "Send text" : "Send search" }

    var body: some View {
        ScreenBody {
            ScreenHeading("", sentTitle,
                          connection.currentDevice?.name ?? "No TV selected")
            Panel {
                Text(isSearch ? "Search on your TV" : isTyping ? "Type on your TV" : "Keyboard unavailable").font(.headline)
                Text(keyboardDetail)
                    .font(.subheadline).foregroundStyle(RemoteTheme.muted)
                TextField(isTyping ? "Type text" : "Type a search", text: query, axis: .vertical)
                    .lineLimit(3...6).textInputAutocapitalization(.sentences)
                    .padding(16).background(RemoteTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
                    .submitLabel(isTyping ? .send : .search).focused($focused).disabled(!canSend || sending)
                    .onSubmit(send).accessibilityIdentifier("searchDraft")
            }
            Button(sending ? "Sending…" : sendLabel, systemImage: "arrow.up.right", action: send)
                .buttonStyle(PrimaryActionStyle())
                .disabled(!canSend || sending || query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Clear draft") { query.wrappedValue = ""; connection.clearMessages() }
                .buttonStyle(SecondaryActionStyle()).disabled(sending || query.wrappedValue.isEmpty)
            ConnectionMessage()
            SupportingCopy(title: "Only when you send", detail: "Your draft stays on this iPhone until you send it. Sending does not confirm a visible change on the TV.")
        }
        .modifier(CloseTool())
    }

    private var sentTitle: String {
        if sentPreview || connection.feedback == "Search sent to TV" { return "Search sent" }
        if connection.feedback == "Text sent to TV" { return "Text sent" }
        return "Keyboard"
    }

    private var keyboardDetail: String {
        if isSearch { return "This connection supports search, not typing into arbitrary TV fields or passwords." }
        if isTyping { return "Open a supported text field on your TV first. This does not start a TV search." }
        return "This connection does not support search or text entry. Use your TV’s keyboard instead."
    }

    private func send() {
        guard canSend, !sending else { return }
        focused = false
        sending = true
        let text = query.wrappedValue
        Task {
            if isTyping { await connection.typeOnTV(text) }
            else { await connection.search(text) }
            sending = false
        }
    }
}

struct RemoteAppItem: Identifiable {
    let id: String
    let name: String
    let monogram: String
    static let demo = [
        Self(id: "netflix", name: "Netflix", monogram: "N"),
        Self(id: "youtube", name: "YouTube", monogram: "▶"),
        Self(id: "prime-video", name: "Prime Video", monogram: "P"),
        Self(id: "disney-plus", name: "Disney+", monogram: "D")
    ]
    static let googleLinks = [
        Self(id: "https://www.youtube.com/tv", name: "YouTube", monogram: "▶"),
        Self(id: "https://www.netflix.com", name: "Netflix", monogram: "N")
    ]
}

struct AppsScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @AppStorage("favoriteTVApps") private var favorites = ""
    @AppStorage("favoriteTVAppsByDevice") private var savedFavorites = Data()
    @State private var query = ""
    @State private var loaded: [TVDevice.ID: [RemoteAppItem]] = [:]
    @State private var failed: TVDevice.ID?
    var forceUnavailable = false
    let setup: () -> Void

    private var catalog: [RemoteAppItem] {
        guard !forceUnavailable else { return [] }
        if connection.isDemo { return RemoteAppItem.demo }
        if connection.supportsAppLinks { return RemoteAppItem.googleLinks }
        return connection.currentDevice.flatMap { loaded[$0.id] } ?? []
    }

    private var favoriteOrder: Binding<String> {
        guard !connection.isDemo, let id = connection.currentDevice?.id else { return $favorites }
        return Binding {
            decodeFavorites()[id] ?? ""
        } set: { value in
            var orders = decodeFavorites()
            orders[id] = value
            if let data = try? JSONEncoder().encode(orders) { savedFavorites = data }
        }
    }

    private func decodeFavorites() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: savedFavorites)) ?? [:]
    }

    private var pinned: [RemoteAppItem] {
        favoriteOrder.wrappedValue.split(separator: ",").compactMap { id in catalog.first { $0.id == id } }
    }
    private var matches: [RemoteAppItem] {
        catalog.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Apps & favorites", connection.currentDevice.map { "Launch on \($0.name)." } ?? "Choose a TV to launch apps.")
            if catalog.isEmpty {
                HeroCard(icon: "square.grid.2x2", title: "Apps unavailable",
                         detail: unavailableDetail)
                Button("Open TV Home") { Task { await connection.send(.home) } }
                    .buttonStyle(PrimaryActionStyle()).disabled(!connection.canControl)
            } else {
                if connection.isDemo {
                    SupportingCopy(title: "Demo catalog", detail: "Sample apps for simulated TVs, not an installed-app list from a real TV.")
                } else if connection.supportsAppLinks {
                    SupportingCopy(title: "App shortcuts", detail: "Google TV does not share its installed apps. These links open on the TV when supported.")
                }
                TextField("Search apps", text: $query)
                    .padding(16).background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .autocorrectionDisabled()
                if !pinned.isEmpty && query.isEmpty {
                    Text("Pinned").font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 98))], spacing: 12) {
                        ForEach(pinned) { app in
                            Button {
                                Task { await connection.launch(AppID(rawValue: app.id), name: app.name) }
                            } label: {
                                VStack(spacing: 12) {
                                    Text(app.monogram).font(.title.weight(.bold))
                                        .frame(width: 56, height: 56)
                                        .background(RemoteTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                                    Text(app.name).font(.subheadline.weight(.medium))
                                }
                                .frame(maxWidth: .infinity, minHeight: 106).padding(8)
                                .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                                .contentShape(RoundedRectangle(cornerRadius: 24))
                            }
                            .buttonStyle(.plain).disabled(!connection.canControl)
                            .accessibilityLabel("Open \(app.name)")
                        }
                    }
                }
                HStack {
                    Text("All apps").font(.title3.weight(.semibold))
                    Spacer()
                    NavigationLink("Edit favorites") { FavoritesScreen(favorites: favoriteOrder, catalog: catalog) }
                        .frame(minHeight: 44)
                }
                if matches.isEmpty { Text("No apps match your search.").foregroundStyle(RemoteTheme.muted) }
                ForEach(matches) { app in
                    Panel {
                        Button {
                            Task { await connection.launch(AppID(rawValue: app.id), name: app.name) }
                        } label: {
                            DetailRow(icon: "play.rectangle", title: app.name, detail: "Open on TV", trailing: "chevron.right")
                        }.buttonStyle(.plain).disabled(!connection.canControl)
                    }
                }
            }
            if connection.currentDevice == nil {
                Button("Find a TV", action: setup).buttonStyle(SecondaryActionStyle())
            }
            ConnectionMessage()
        }
        .task(id: connection.canControl ? connection.currentDevice?.id : nil) {
            guard !forceUnavailable, connection.canControl, connection.supportsAppList,
                  let id = connection.currentDevice?.id else { return }
            do {
                let apps = try await connection.loadApps()
                try Task.checkCancellation()
                loaded[id] = apps.map { RemoteAppItem(id: $0.id.rawValue, name: $0.name, monogram: String($0.name.prefix(1))) }
                failed = nil
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                failed = id
            }
        }
    }

    private var unavailableDetail: String {
        if !forceUnavailable, connection.supportsAppList, let id = connection.currentDevice?.id {
            if failed == id { return "Could not read the installed apps from this TV. Use Home to browse apps on your TV." }
            if loaded[id]?.isEmpty == true { return "This TV did not list any apps." }
            if connection.canControl { return "Looking up installed apps…" }
        }
        return "This connection doesn’t supply an installed-app list. Use Home to browse apps on your TV."
    }
}

struct FavoritesScreen: View {
    @Binding var favorites: String
    let catalog: [RemoteAppItem]
    private var ids: [String] { favorites.split(separator: ",").map(String.init) }
    private var ordered: [RemoteAppItem] {
        ids.compactMap { id in catalog.first { $0.id == id } } + catalog.filter { !ids.contains($0.id) }
    }

    var body: some View {
        List {
            Text("Edit favorites").font(RemoteTheme.title).listRowBackground(RemoteTheme.canvas)
            Text("Pin apps for quick access. Drag to reorder pinned apps.")
                .foregroundStyle(RemoteTheme.muted).listRowBackground(RemoteTheme.canvas)
            ForEach(ordered) { app in
                HStack {
                    Text(app.name).frame(maxWidth: .infinity, alignment: .leading)
                    Button(ids.contains(app.id) ? "Unpin \(app.name)" : "Pin \(app.name)",
                           systemImage: ids.contains(app.id) ? "star.fill" : "star") {
                        var next = ids
                        if next.contains(app.id) { next.removeAll { $0 == app.id } } else { next.append(app.id) }
                        favorites = next.joined(separator: ",")
                    }.labelStyle(.iconOnly).frame(width: 44, height: 44).buttonStyle(.plain)
                }
                .listRowBackground(RemoteTheme.surface)
                .accessibilityAction(named: "Move up") { move(app.id, by: -1) }
                .accessibilityAction(named: "Move down") { move(app.id, by: 1) }
            }
            .onMove { source, destination in
                var all = ordered.map(\.id)
                all.move(fromOffsets: source, toOffset: destination)
                favorites = all.filter { ids.contains($0) }.joined(separator: ",")
            }
        }
        .scrollContentBackground(.hidden).background(RemoteTheme.canvas)
        .toolbar { EditButton().frame(minWidth: 44, minHeight: 44) }
        .modifier(TaskSurface())
    }

    private func move(_ id: String, by offset: Int) {
        var next = ids
        guard let index = next.firstIndex(of: id), next.indices.contains(index + offset) else { return }
        next.swapAt(index, index + offset)
        favorites = next.joined(separator: ",")
    }
}

struct PointerSurface: View {
    @Environment(RemoteViewModel.self) private var connection

    var body: some View {
        VStack(spacing: 12) {
            if connection.supportsPointer && connection.canControl {
                RoundedRectangle(cornerRadius: 24).fill(RemoteTheme.surface)
                    .overlay {
                        VStack(spacing: 16) {
                            Image(systemName: "hand.draw").font(.largeTitle).foregroundStyle(RemoteTheme.accent)
                            Text("Swipe to move").foregroundStyle(RemoteTheme.muted)
                        }
                    }
                    .frame(height: 252)
                    .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                        Task { await connection.movePointer(x: value.translation.width, y: value.translation.height) }
                    })
                    .accessibilityHidden(true)
                Button("Select") { Task { await connection.send(.select) } }.buttonStyle(SecondaryActionStyle())
                Text("Use Buttons mode for accessible directional controls.")
                    .font(.footnote).foregroundStyle(RemoteTheme.muted)
            } else {
                HeroCard(icon: "hand.point.up.left", title: "Keep using Buttons",
                         detail: connection.isDemo
                         ? "The Bedroom demo TV supports the touchpad. Choose it in My TVs, or switch back to Buttons."
                         : "This TV or connection does not support pointer input. All directional buttons remain available.")
            }
        }
    }
}

struct TrackpadScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("", "Touchpad", "Swipe to move. Use Select to choose.")
            PointerSurface()
        }.modifier(CloseTool())
    }
}

enum VoicePhase: String, CaseIterable {
    case introduction, permission, listening, result, clarify, retry, unavailable
}

struct VoiceScreen: View {
    var phase: VoicePhase = .unavailable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenBody {
            ScreenHeading("", phase == .permission ? "Use your voice" : "Talk to your TV", "Only when you ask.")
            HeroCard(icon: phase == .unavailable ? "mic.slash" : "mic",
                     title: heading, detail: detail)
            if phase == .introduction {
                Panel {
                    Text("Try saying").font(.headline)
                    Text("“Turn the volume down”\n“Go Home”\n“Pause”").foregroundStyle(RemoteTheme.muted)
                }
            }
            if phase == .clarify {
                Button("Volume down") {}.buttonStyle(SecondaryActionStyle()).disabled(true)
                Button("Channel down") {}.buttonStyle(SecondaryActionStyle()).disabled(true)
            }
            Button(phase == .listening ? "Stop listening" : "Back to remote") { dismiss() }
                .buttonStyle(PrimaryActionStyle())
            SupportingCopy(title: "Buttons always work", detail: "Basic control stays free. No audio is recorded by this build, and no cloud speech service is used.")
        }
        .modifier(CloseTool())
    }

    private var heading: String {
        switch phase {
        case .introduction: "Say it. Then watch."
        case .permission: "Speak to your TV"
        case .listening: "Listening…"
        case .result: "Command acknowledged"
        case .clarify: "Which did you mean?"
        case .retry: "Let’s try that again"
        case .unavailable: "Voice isn’t connected yet"
        }
    }
    private var detail: String {
        switch phase {
        case .introduction: "Use simple commands for navigation, playback and volume."
        case .permission: "Microphone and on-device speech access will be requested only when you choose to listen."
        case .listening: "“Turn the volume down”"
        case .result: "The driver acknowledged Volume down. This does not confirm the audible TV volume changed."
        case .clarify: "“Turn it down” could mean volume or channel. Nothing has been sent."
        case .retry: "We couldn’t recognize that command. Nothing was sent to your TV."
        case .unavailable: "On-device voice is being integrated separately. Use your remote buttons in the meantime."
        }
    }
}

struct InputsScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @State private var inputs: [TVInput]?
    @State private var failure: String?

    var body: some View {
        if connection.supportsInputMenu || connection.supportsInputSelection {
            ScreenBody {
                ScreenHeading("", "Inputs", connection.currentDevice?.name ?? "No TV selected")
                if connection.supportsInputMenu {
                    Button("Open TV input menu") { Task { await connection.openTVInputMenu() } }
                        .buttonStyle(PrimaryActionStyle()).disabled(!connection.canControl)
                } else if let inputs, !inputs.isEmpty {
                    ForEach(inputs) { input in
                        Panel {
                            Button {
                                Task { await connection.selectInput(input) }
                            } label: {
                                DetailRow(icon: "rectangle.on.rectangle", title: input.name,
                                          detail: "Switch input", trailing: "chevron.right")
                            }.buttonStyle(.plain).disabled(!connection.canControl)
                        }
                    }
                } else {
                    HeroCard(icon: "rectangle.on.rectangle", title: "Inputs",
                             detail: failure ?? (inputs == nil ? "Looking up inputs…" : "The TV did not list any inputs."))
                }
                ConnectionMessage()
            }
            .modifier(TaskSurface())
            .task(id: connection.canControl) {
                guard connection.canControl, connection.supportsInputSelection else { return }
                do { inputs = try await connection.loadInputs(); failure = nil }
                catch is CancellationError {}
                catch TVError.notSupported { failure = "This TV did not provide an input list." }
                catch { failure = "Could not read inputs from the TV." }
            }
        } else {
            UnavailableScreen(title: "Inputs", icon: "rectangle.on.rectangle",
                              reason: "This connection does not offer input controls. Use your TV’s physical remote to change inputs.")
        }
    }
}

struct KeypadScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("", "Channel keypad", "Channel numbers are not supported by this driver.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                ForEach(1...9, id: \.self) { digit in
                    Text("\(digit)").font(.title2).frame(maxWidth: .infinity, minHeight: 64)
                        .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                }
                Text("0").font(.title2).frame(maxWidth: .infinity, minHeight: 64)
                    .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .foregroundStyle(RemoteTheme.disabled).accessibilityLabel("Unavailable numeric keypad")
            SupportingCopy(title: "Use channel buttons", detail: "Relative channel buttons remain on the remote when connected. No guessed channel numbers are sent.")
        }.modifier(TaskSurface())
    }
}
