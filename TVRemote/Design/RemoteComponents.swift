import SwiftUI

private struct DesignPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isDesignPreview: Bool {
        get { self[DesignPreviewKey.self] }
        set { self[DesignPreviewKey.self] = newValue }
    }
}

struct SecondaryActionStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(destructive ? RemoteTheme.danger : RemoteTheme.text)
            .background(RemoteTheme.raised, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.5)
    }
}

struct HeroCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        Panel {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(RemoteTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 158)
                .background(RemoteTheme.accentSoft, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(RemoteTheme.muted)
        }
    }
}

struct SupportingCopy: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.subheadline)
        }
        .foregroundStyle(RemoteTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ControlKeyStyle: ButtonStyle {
    var size: CGFloat = 56
    var accent = false
    var clear = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.weight(.medium))
            .frame(width: size, height: size)
            .foregroundStyle(isEnabled ? (accent ? RemoteTheme.onAccent : RemoteTheme.text) : RemoteTheme.disabled)
            .background(accent ? RemoteTheme.accent : (clear ? Color.clear : RemoteTheme.surface),
                        in: RoundedRectangle(cornerRadius: accent ? size / 2 : 20))
            .contentShape(RoundedRectangle(cornerRadius: accent ? size / 2 : 20))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct TaskSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(RemoteTheme.canvas, for: .navigationBar)
    }
}

struct UnavailableScreen: View {
    let title: String
    let icon: String
    let reason: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenBody {
            ScreenHeading("", title, "Your remote is still here.")
            HeroCard(icon: icon, title: "Not available for this connection", detail: reason)
            Button("Back to remote") { dismiss() }.buttonStyle(PrimaryActionStyle())
            SupportingCopy(title: "No upgrade needed", detail: "Capabilities depend on the TV and its driver, not a subscription.")
        }
        .modifier(TaskSurface())
    }
}
