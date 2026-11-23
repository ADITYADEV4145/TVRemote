import SwiftUI
import TVDriverKit

struct SettingsScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("TV REMOTE  /  04", "Settings", "Get help or learn what your remote can do.")
            Panel {
                NavigationLink {
                    DiagnosticsScreen()
                } label: {
                    DetailRow(icon: "wifi.exclamationmark", title: "Fix my connection",
                              detail: "TV status and troubleshooting", trailing: "chevron.right")
                }
                NavigationLink {
                    CompatibilityScreen()
                } label: {
                    DetailRow(icon: "checkmark.shield", title: "Compatibility",
                              detail: "Supported platforms and limits", trailing: "chevron.right")
                }
                NavigationLink {
                    PrivacyScreen()
                } label: {
                    DetailRow(icon: "lock.shield", title: "Privacy",
                              detail: "What this preview collects", trailing: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            Panel {
                NavigationLink {
                    UpgradeScreen()
                } label: {
                    DetailRow(icon: "star.circle", title: "TV Remote Plus",
                              detail: "Preview plans · No weekly subscription", trailing: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DiagnosticsScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var showRepair = false

    var body: some View {
        ScreenBody {
            ScreenHeading("CONNECTION HELP", "Fix my connection",
                          connection.isDemo ? "Demo results only. Nothing on your network was checked."
                          : "Check the TV connection and common setup issues.")
            Panel {
                DetailRow(icon: "tv", title: connection.currentDevice?.name ?? "No TV selected",
                          detail: connection.state.rawValue)
                if connection.currentDevice != nil {
                    Button("Retry connection", systemImage: "arrow.clockwise") {
                        Task {
                            if !(await connection.reconnect()), connection.pairingDevice != nil {
                                showRepair = true
                            }
                        }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(connection.isConnecting)
                }
                ShareLink(item: "TV Remote connection status: \(connection.state.rawValue). Mode: \(connection.isDemo ? "Demo" : "Live").") {
                    Label("Share redacted status", systemImage: "square.and.arrow.up")
                        .frame(minHeight: RemoteTheme.target)
                }
            }
            Panel {
                DetailRow(icon: "wifi", title: "Wi-Fi and TV network",
                          detail: "Connect your iPhone and TV to the same Wi-Fi. Avoid guest networks.")
                DetailRow(icon: "lock.shield", title: "Local Network permission",
                          detail: connection.isDemo ? "Not requested in demo mode."
                          : "In iPhone Settings, allow Local Network access for TV Remote.")
                DetailRow(icon: "moon.zzz", title: "Network standby",
                          detail: "If your TV will not wake, check its network standby or quick-start setting.")
                DetailRow(icon: "key", title: "Pairing credentials",
                          detail: "If the TV no longer trusts this remote, pair again from My TVs.")
            }
            ConnectionMessage()
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRepair) {
            NavigationStack { SetupScreen(initiallyStarted: true) { showRepair = false } }
        }
    }
}

private struct CompatibilityScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("KNOW BEFORE YOU CONNECT", "Compatibility",
                          "This app uses Wi-Fi. An iPhone cannot control infrared-only TVs.")
            Panel {
                DetailRow(icon: "testtube.2", title: "Demo platforms",
                          detail: "The Roku TV and Google TV examples are simulated.")
                DetailRow(icon: "tv", title: "Planned first-release platforms",
                          detail: "Roku TV, Google TV, Samsung Tizen and LG webOS.")
                DetailRow(icon: "network.slash", title: "No hardware support in this build",
                          detail: "No physical TV was connected or tested. Features may vary by model.")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("LOCAL BY DESIGN", "Privacy", "No account is needed to use this preview.")
            Panel {
                DetailRow(icon: "iphone", title: "On this iPhone",
                          detail: "Favorite app pins are stored locally. Demo connections reset when the app restarts.")
                DetailRow(icon: "mic.slash", title: "No microphone access",
                          detail: "The preview does not record audio or upload diagnostics.")
                DetailRow(icon: "square.and.arrow.up", title: "You choose what to share",
                          detail: "The share sheet exports connection status without TV names, addresses or credentials.")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct UpgradeScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("OPTIONAL UPGRADE", "TV Remote Plus",
                          "Core controls stay free. No weekly plan and no ads.")
            Panel {
                DetailRow(icon: "calendar", title: "Yearly · $14.99",
                          detail: "7-day free trial planned · then billed yearly", trailing: "star.fill")
                Divider()
                DetailRow(icon: "calendar", title: "Monthly · $2.99",
                          detail: "Billed monthly")
                Divider()
                DetailRow(icon: "infinity", title: "Lifetime · $29.99",
                          detail: "One-time purchase")
            }
            Text("Preview pricing only. Purchases and restores aren’t available in this build.")
                .font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.secondary)
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}
