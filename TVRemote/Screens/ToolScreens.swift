import SwiftUI
import TVDriverKit

struct KeyboardScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScreenBody {
            ScreenHeading("REMOTE TOOL", "Keyboard", "Use your iPhone to send a search to your TV.")
            Panel {
                DetailRow(icon: "keyboard", title: connection.currentDevice?.name ?? "No TV connected",
                          detail: connection.canControl ? "Ready to receive search" : "Connect a TV first")
                TextField("Type a search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .focused($focused)
                    .disabled(!connection.canControl)
                    .onSubmit(send)
                Button("Send search", systemImage: "arrow.up.right") { send() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(!connection.canControl || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ConnectionMessage()
        }
        .modifier(CloseTool())
    }

    private func send() {
        focused = false
        Task { await connection.search(query) }
    }
}

struct AppsScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @AppStorage("favoriteTVApps") private var favorites = ""
    let setup: () -> Void

    private struct DemoApp: Identifiable {
        let id: String
        let name: String
        let icon: String
    }

    private let catalog = [
        DemoApp(id: "netflix", name: "Netflix", icon: "film"),
        DemoApp(id: "youtube", name: "YouTube", icon: "play.rectangle"),
        DemoApp(id: "prime-video", name: "Prime Video", icon: "play.tv"),
        DemoApp(id: "disney-plus", name: "Disney+", icon: "sparkles.tv")
    ]

    private var pinned: Set<String> { Set(favorites.split(separator: ",").map(String.init)) }

    var body: some View {
        ScreenBody {
            ScreenHeading("TV REMOTE  /  03", "Apps & favorites", "Launch a streaming app or pin it for next time.")
            if !connection.canControl {
                Panel {
                    DetailRow(icon: "tv", title: "A connected TV is needed",
                              detail: "You can still pin your favorites now.")
                    if connection.currentDevice == nil {
                        Button("Find a TV") { setup() }.buttonStyle(PrimaryActionStyle())
                    }
                }
            }
            let favoriteApps = catalog.filter { pinned.contains($0.id) }
            if !favoriteApps.isEmpty {
                appSection("Pinned", apps: favoriteApps)
            }
            appSection(connection.isDemo ? "Demo app catalog" : "Available apps",
                       apps: connection.isDemo ? catalog.filter { !pinned.contains($0.id) } : [])
            ConnectionMessage()
        }
    }

    @ViewBuilder
    private func appSection(_ title: String, apps: [DemoApp]) -> some View {
        if !apps.isEmpty {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Panel {
                ForEach(apps) { app in
                    HStack {
                        Button {
                            Task { await connection.launch(AppID(rawValue: app.id), name: app.name) }
                        } label: {
                            DetailRow(icon: app.icon, title: app.name,
                                      detail: connection.canControl ? "Open on TV" : "Connect to launch")
                        }
                        .buttonStyle(.plain)
                        .disabled(!connection.canControl)
                        Button(pinned.contains(app.id) ? "Unpin \(app.name)" : "Pin \(app.name)",
                               systemImage: pinned.contains(app.id) ? "star.fill" : "star") {
                            var updated = pinned
                            if updated.remove(app.id) == nil { updated.insert(app.id) }
                            favorites = updated.sorted().joined(separator: ",")
                        }
                        .labelStyle(.iconOnly)
                        .frame(width: RemoteTheme.target, height: RemoteTheme.target)
                    }
                }
            }
        }
    }
}

struct TrackpadScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var previous = CGSize.zero

    var body: some View {
        ScreenBody {
            ScreenHeading("REMOTE TOOL", "Trackpad", "Drag to move the pointer. Tap to select.")
            Panel {
                if connection.supportsPointer && connection.canControl {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(RemoteTheme.key)
                        .overlay {
                            Image(systemName: "cursorarrow.motionlines")
                                .font(.largeTitle)
                                .foregroundStyle(RemoteTheme.accent)
                        }
                        .frame(height: 242)
                        .gesture(DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                let x = value.translation.width - previous.width
                                let y = value.translation.height - previous.height
                                previous = value.translation
                                Task { await connection.movePointer(x: x, y: y) }
                            }
                            .onEnded { _ in previous = .zero })
                        .onTapGesture { choose() }
                        .accessibilityHidden(true)
                    Button("Select", action: choose)
                        .buttonStyle(PrimaryActionStyle())
                } else {
                    DetailRow(icon: "hand.point.up.left", title: "Pointer unavailable",
                              detail: connection.isDemo
                              ? "Connect the Bedroom demo TV to try the trackpad."
                              : "Connect a TV that supports pointer input.")
                }
            }
            ConnectionMessage()
        }
        .modifier(CloseTool())
    }

    private func choose() {
        Task { await connection.send(.select) }
    }
}

struct VoiceScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("REMOTE TOOL", "Voice", "Ask for what you want to watch or change.")
            Panel {
                DetailRow(icon: "mic.slash", title: "Not available in this build",
                          detail: "Voice control will use on-device speech. This preview does not record audio.")
            }
        }
        .modifier(CloseTool())
    }
}
