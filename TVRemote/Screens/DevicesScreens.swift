import SwiftUI
import TVDriverKit

struct SetupScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var hasStarted: Bool
    @State private var manual = false
    @State private var address = ""
    @State private var code = ""
    let connected: () -> Void

    init(initiallyStarted: Bool = false, connected: @escaping () -> Void) {
        _hasStarted = State(initialValue: initiallyStarted)
        self.connected = connected
    }

    var body: some View {
        ScreenBody {
            ScreenHeading("GET CONNECTED", "Find your TV",
                          "Your iPhone and TV need to be on the same Wi-Fi.")
            if !hasStarted {
                Panel {
                    DetailRow(icon: "wifi", title: "Local Network",
                              detail: connection.isDemo
                              ? "This demo uses simulated TVs and never accesses your network."
                              : "Allow Local Network access when asked so your iPhone can find your TV.")
                    Button("Find TVs") {
                        hasStarted = true
                    }
                    .buttonStyle(PrimaryActionStyle())
                }
            } else if let device = connection.pairingDevice {
                Panel {
                    DetailRow(icon: "number.square", title: "Pair with \(device.name)",
                              detail: connection.isDemo ? "Use 123456 for this demo."
                              : "Enter the code shown on your TV.")
                    TextField("TV pairing code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Pair TV") {
                        Task { if await connection.submit(code: code) { connected() } }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.isConnecting)
                    Button("Choose a different TV") {
                        code = ""
                        connection.cancelPairing()
                    }
                    .frame(minHeight: RemoteTheme.target)
                }
            } else {
                Panel {
                    if connection.isDiscovering {
                        ProgressView("Looking for TVs")
                    } else if connection.devices.isEmpty {
                        Text("No TVs found yet.").foregroundStyle(RemoteTheme.secondary)
                        Button("Search again") { Task { await connection.discover() } }
                            .frame(minHeight: RemoteTheme.target)
                    }
                    ForEach(connection.devices) { device in
                        Button {
                            Task { if await connection.select(device) { connected() } }
                        } label: {
                            DetailRow(icon: "tv", title: device.name, detail: device.platform,
                                      trailing: "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .disabled(connection.isConnecting)
                    }
                }
                if connection.supportsManualAddress {
                    Panel {
                        DisclosureGroup("Enter IP address", isExpanded: $manual) {
                            VStack(spacing: 12) {
                                if connection.isDemo {
                                    Text("Demo addresses: 192.0.2.10 or 192.0.2.11")
                                        .font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.secondary)
                                }
                                TextField("IP address", text: $address)
                                    .keyboardType(.numbersAndPunctuation)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                Button("Find by IP") {
                                    Task { if await connection.find(address: address) { connected() } }
                                }
                                .buttonStyle(PrimaryActionStyle())
                                .disabled(address.isEmpty || connection.isConnecting)
                            }
                            .padding(.top, 8)
                        }
                        .frame(minHeight: RemoteTheme.target)
                    }
                }
            }
            if connection.isConnecting { ProgressView("Connecting to TV") }
            ConnectionMessage()
        }
        .task(id: hasStarted) {
            if hasStarted { await connection.discover() }
        }
        .modifier(CloseTool())
        .interactiveDismissDisabled(connection.isConnecting)
        .onDisappear { connection.cancelPairing() }
    }
}

struct DevicesScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var code = ""
    @State private var forgetCandidate: TVDevice?
    @State private var confirmForget = false
    let add: () -> Void
    let connected: () -> Void

    var body: some View {
        List {
            ScreenHeading("TV REMOTE  /  02", "My TVs", "Switch rooms without relearning your remote.")
                .deviceListRow()
            if let pairingDevice = connection.pairingDevice {
                Panel {
                    DetailRow(icon: "number.square", title: "Pair with \(pairingDevice.name)",
                              detail: connection.isDemo ? "Use 123456 for this demo."
                              : "Enter the code shown on your TV.")
                    TextField("TV pairing code", text: $code)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Pair again") {
                        Task { if await connection.submit(code: code) { connected() } }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.isConnecting)
                    Button("Cancel") {
                        code = ""
                        connection.cancelPairing()
                    }
                    .frame(minHeight: RemoteTheme.target)
                }
                .deviceListRow()
            }
            if connection.savedDevices.isEmpty {
                Panel {
                    DetailRow(icon: "tv", title: "No TVs paired yet", detail: "Add a TV to get started.")
                }
                .deviceListRow()
            }
            ForEach(connection.savedDevices) { device in
                savedTV(device)
                    .deviceListRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        forgetButton(for: device)
                    }
            }
            Button("Add a TV", systemImage: "plus") { add() }
                .buttonStyle(PrimaryActionStyle())
                .deviceListRow()
            if connection.error != nil || connection.feedback != nil {
                ConnectionMessage()
                    .deviceListRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(RemoteTheme.canvas.ignoresSafeArea())
        .foregroundStyle(RemoteTheme.ink)
        .confirmationDialog("Forget this TV?", isPresented: $confirmForget, presenting: forgetCandidate) { device in
            Button("Forget \(device.name)", role: .destructive) {
                Task { await connection.forget(device) }
            }
        } message: { device in
            Text("You’ll need to pair \(device.name) again before using it.")
        }
    }

    private func savedTV(_ device: TVDevice) -> some View {
        let isCurrent = connection.currentDevice?.id == device.id
        return Panel {
            HStack(spacing: 8) {
                Button {
                    Task {
                        let didConnect: Bool
                        if isCurrent {
                            didConnect = connection.canControl ? true : await connection.reconnect()
                        } else {
                            didConnect = await connection.select(device)
                        }
                        if didConnect { connected() }
                    }
                } label: {
                    DetailRow(icon: "tv", title: device.name,
                              detail: isCurrent ? "\(device.platform) · \(connection.state.rawValue)" : device.platform,
                              trailing: isCurrent ? "checkmark.circle.fill" : nil)
                }
                .buttonStyle(.plain)
                .contextMenu { forgetButton(for: device) }

                Menu {
                    forgetButton(for: device)
                } label: {
                    Label("Options for \(device.name)", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: RemoteTheme.target, height: RemoteTheme.target)
                        .contentShape(Rectangle())
                }
            }
        }
        .disabled(connection.isConnecting)
    }

    private func forgetButton(for device: TVDevice) -> some View {
        Button("Forget", systemImage: "trash", role: .destructive) {
            forgetCandidate = device
            confirmForget = true
        }
        .disabled(connection.isConnecting)
    }
}

private extension View {
    func deviceListRow() -> some View {
        listRowInsets(EdgeInsets(top: 8, leading: RemoteTheme.gutter, bottom: 8, trailing: RemoteTheme.gutter))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
