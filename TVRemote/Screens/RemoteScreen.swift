import SwiftUI

struct RemoteScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("hapticsEnabled") private var haptics = true
    @State private var haptic = 0
    @State private var touchpad = false
    var forceLarge = false
    let open: (RootScreen.Tool) -> Void

    init(touchpad: Bool = false, forceLarge: Bool = false, open: @escaping (RootScreen.Tool) -> Void) {
        _touchpad = State(initialValue: touchpad)
        self.forceLarge = forceLarge
        self.open = open
    }

    private var large: Bool { forceLarge || largeControls || dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScreenBody(spacing: 8) {
            header
            HStack(alignment: .top) {
                utility("Power", "power") { press(.power) }.disabled(!connection.canPower)
                Spacer()
                utility("Input", "rectangle.on.rectangle") { open(.inputs) }
                Spacer()
                utility("Keyboard", "keyboard") { open(.keyboard) }
            }
            .padding(.horizontal, large ? 0 : 24)
            modePicker
            if touchpad && connection.supportsPointer {
                PointerSurface()
            } else {
                DirectionDisc(large: large, enabled: connection.canControl, press: press)
                    .frame(maxWidth: .infinity)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { navigationKeys }
                VStack(spacing: 12) { navigationKeys }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    rocker("Volume", up: .volumeUp, down: .volumeDown)
                    rocker("Channel", up: .channelUp, down: .channelDown)
                }
                VStack(spacing: 8) {
                    rocker("Volume", up: .volumeUp, down: .volumeDown)
                    rocker("Channel", up: .channelUp, down: .channelDown)
                }
            }
            ConnectionMessage()
        }
        .modifier(ScreenActions {
            Button("Talk to your TV") { open(.voice) }.buttonStyle(PrimaryActionStyle())
            if connection.currentDevice == nil {
                Button("Find a TV") { open(.setup) }.buttonStyle(SecondaryActionStyle())
            }
        })
        .onChange(of: connection.currentDevice?.id) { touchpad = false }
        .onChange(of: connection.supportsPointer) {
            if !connection.supportsPointer { touchpad = false }
        }
        .sensoryFeedback(.selection, trigger: haptic)
    }

    private var modePicker: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                modeButton("Buttons", selected: !touchpad || !connection.supportsPointer) { touchpad = false }
                modeButton("Touchpad", selected: touchpad && connection.supportsPointer) { touchpad = true }
                    .disabled(!connection.supportsPointer)
                    .accessibilityHint(connection.supportsPointer ? "Swipe to move the TV pointer." : "Not supported by this TV or connection. Use Buttons.")
            }
            .padding(3)
            .background(RemoteTheme.raised, in: Capsule())
            .frame(maxWidth: large ? .infinity : 280)
            .frame(maxWidth: .infinity)
            if !connection.supportsPointer {
                Text("Touchpad isn’t supported on this connection.")
                    .font(.footnote).foregroundStyle(RemoteTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote mode")
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? RemoteTheme.surface : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RemoteTheme.text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var navigationKeys: some View {
        Group {
            utility("Back", "arrow.uturn.backward") { press(.back) }
            Spacer(minLength: 0)
            utility("Home", "house") { press(.home) }
            Spacer(minLength: 0)
            utility("Play/pause", "play") { press(.playPause) }
            Spacer(minLength: 0)
            utility("Mute", "speaker.slash") { press(.mute) }
        }
        .disabled(!connection.canControl)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(connection.currentDevice?.name ?? "Your TV remote")
                .font(RemoteTheme.title).accessibilityAddTraits(.isHeader)
            HStack {
                Text(connection.isConnecting ? "Connecting" : connection.state.rawValue)
                    .foregroundStyle(RemoteTheme.muted)
                    .accessibilityHint(connection.canPower && !connection.canControl ? "Power can try to wake this TV." : "")
                if connection.isDemo {
                    Text("DEMO").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RemoteTheme.raised, in: Capsule())
                }
                Spacer()
                if [.recovering, .degraded, .needsRepair, .asleep].contains(connection.state) {
                    NavigationLink("Fix connection", value: RootScreen.RemoteDestination.diagnostics)
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
            }
            .font(.subheadline)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private func utility(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Button(title, systemImage: icon, action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(ControlKeyStyle(size: large ? 72 : 56))
                .accessibilityIdentifier(title)
            Text(title).font(.caption).foregroundStyle(RemoteTheme.muted)
                .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
        }
    }

    private func rocker(_ title: String, up: RemoteKey, down: RemoteKey) -> some View {
        HStack(spacing: 0) {
            Button("\(title) down", systemImage: "minus") { press(down) }
                .labelStyle(.iconOnly).buttonStyle(ControlKeyStyle(clear: true))
            Text(title).font(.subheadline).foregroundStyle(RemoteTheme.muted)
                .frame(maxWidth: .infinity).accessibilityHidden(true)
            Button("\(title) up", systemImage: "plus") { press(up) }
                .labelStyle(.iconOnly).buttonStyle(ControlKeyStyle(clear: true))
        }
        .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .disabled(up == .channelUp ? !connection.canChangeChannel : !connection.canControl)
    }

    private func press(_ key: RemoteKey) {
        if haptics { haptic += 1 }
        Task { await connection.send(key) }
    }
}

struct DirectionDisc: View {
    var large = false
    var enabled = true
    var press: (RemoteKey) -> Void

    var body: some View {
        Group {
            if large {
                VStack(spacing: 12) {
                    arrow("Up", "chevron.up", .up)
                    HStack(spacing: 16) {
                        arrow("Left", "chevron.left", .left)
                        okay
                        arrow("Right", "chevron.right", .right)
                    }
                    arrow("Down", "chevron.down", .down)
                }
                .padding(16)
                .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            } else {
                ZStack {
                    Circle().fill(RemoteTheme.surface)
                    arrow("Up", "chevron.up", .up).offset(y: -88)
                    arrow("Left", "chevron.left", .left).offset(x: -88)
                    okay
                    arrow("Right", "chevron.right", .right).offset(x: 88)
                    arrow("Down", "chevron.down", .down).offset(y: 88)
                }
                .frame(width: 252, height: 252)
            }
        }
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Directional controls")
    }

    private var okay: some View {
        Button("OK") { press(.select) }.buttonStyle(ControlKeyStyle(size: 84, accent: true))
    }

    private func arrow(_ title: String, _ symbol: String, _ key: RemoteKey) -> some View {
        Button(title, systemImage: symbol) { press(key) }
            .labelStyle(.iconOnly).buttonStyle(ControlKeyStyle(size: large ? 72 : 56, clear: true))
    }
}
