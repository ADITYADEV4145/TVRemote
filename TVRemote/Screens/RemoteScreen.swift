import SwiftUI
import TVDriverKit

struct RemoteScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var haptic = 0
    let open: (RootScreen.Tool) -> Void

    var body: some View {
        ScreenBody {
            ScreenHeading("TV REMOTE  /  01", "Remote")
            devicePanel
            Panel {
                directionPad
                HStack(spacing: 8) {
                    control("Back", "arrow.uturn.backward", .back)
                    control("Home", "house.fill", .home)
                    control("Play or pause", "playpause.fill", .playPause)
                }
            }
            HStack(spacing: 10) {
                rocker("Volume", up: .volumeUp, down: .volumeDown)
                control("Mute", "speaker.slash.fill", .mute)
                    .frame(maxWidth: 64)
                rocker("Channel", up: .channelUp, down: .channelDown)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { tools }
                VStack(spacing: 10) { tools }
            }
            if connection.currentDevice != nil { ConnectionMessage() }
        }
        .sensoryFeedback(.selection, trigger: haptic)
    }

    private var devicePanel: some View {
        let layout = dynamicTypeSize.isAccessibilitySize && connection.currentDevice == nil
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout())
        return Panel {
            layout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(connection.currentDevice?.name ?? "No TV selected")
                        .font(.headline)
                    Label(connection.isConnecting ? "Connecting" : connection.state.rawValue,
                          systemImage: connection.canControl ? "checkmark.circle.fill" : "circle.dotted")
                        .font(RemoteTheme.metadata)
                        .foregroundStyle(connection.canControl ? RemoteTheme.healthy : RemoteTheme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if connection.currentDevice != nil {
                    control("Power", "power", .power, enabled: connection.canPower)
                        .frame(width: 52)
                } else {
                    Button("Find a TV") { open(.setup) }
                        .buttonStyle(PrimaryActionStyle())
                        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                }
            }
            if connection.isDemo {
                Text("DEMO MODE").font(RemoteTheme.label).tracking(1.4)
                    .foregroundStyle(RemoteTheme.secondary)
                    .accessibilityLabel("Demo mode")
            }
        }
    }

    private var directionPad: some View {
        Grid(horizontalSpacing: 7, verticalSpacing: 7) {
            GridRow {
                Color.clear.accessibilityHidden(true)
                control("Up", "chevron.up", .up)
                Color.clear.accessibilityHidden(true)
            }
            GridRow {
                control("Left", "chevron.left", .left)
                Button("OK") { press(.select) }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(RemoteTheme.accent, in: RoundedRectangle(cornerRadius: 15))
                    .foregroundStyle(RemoteTheme.onAccent)
                    .buttonStyle(KeyPressStyle())
                    .disabled(!connection.canControl)
                control("Right", "chevron.right", .right)
            }
            GridRow {
                Color.clear.accessibilityHidden(true)
                control("Down", "chevron.down", .down)
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(maxWidth: 294)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { gesture in
            guard connection.canControl else { return }
            let delta = gesture.translation
            if abs(delta.width) > abs(delta.height) {
                press(delta.width < 0 ? .left : .right)
            } else {
                press(delta.height < 0 ? .up : .down)
            }
        })
    }

    private func rocker(_ name: String, up: RemoteKey, down: RemoteKey) -> some View {
        VStack(spacing: 1) {
            control("\(name) up", "plus", up)
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(RemoteTheme.secondary)
                .accessibilityHidden(true)
            control("\(name) down", "minus", down)
        }
        .padding(5)
        .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var tools: some View {
        Group {
            Button { open(.voice) } label: {
                Label("Voice", systemImage: "mic.fill")
            }
            .buttonStyle(PrimaryActionStyle())
            Button { open(.keyboard) } label: {
                Label("Keyboard", systemImage: "keyboard")
                    .frame(minHeight: RemoteTheme.target)
            }
            .buttonStyle(.bordered)
            Button { open(.trackpad) } label: {
                Label("Trackpad", systemImage: "hand.point.up.left")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: RemoteTheme.target, minHeight: RemoteTheme.target)
            }
            .buttonStyle(.bordered)
        }
    }

    private func control(_ title: String, _ icon: String, _ key: RemoteKey, enabled: Bool? = nil) -> some View {
        Button(title, systemImage: icon) { press(key) }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: RemoteTheme.target)
            .foregroundStyle(key == .power ? RemoteTheme.warning : RemoteTheme.ink)
            .background(RemoteTheme.key, in: RoundedRectangle(cornerRadius: 14))
            .buttonStyle(KeyPressStyle())
            .disabled(!(enabled ?? connection.canControl))
    }

    private func press(_ key: RemoteKey) {
        haptic += 1
        Task { await connection.send(key) }
    }
}

private struct KeyPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.64 : 1) : 0.42)
    }
}
