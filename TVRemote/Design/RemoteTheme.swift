import SwiftUI
import UIKit

enum RemoteTheme {
    static let canvas = adaptive(0xF3F4F8, 0x10121A)
    static let surface = adaptive(0xFFFFFF, 0x1D202B)
    static let raised = adaptive(0xE7EAF2, 0x2A2E3B)
    static let text = adaptive(0x171A26, 0xF7F8FC)
    static let muted = adaptive(0x5D6475, 0xA8AFC2)
    static let accent = adaptive(0x3C50C8, 0xB5C1FF)
    static let onAccent = adaptive(0xFFFFFF, 0x1B2451)
    static let accentSoft = adaptive(0xE5E9FF, 0x282F4A)
    static let success = adaptive(0x1D7055, 0x8DD6BA)
    static let warning = adaptive(0x805700, 0xEBC887)
    static let danger = adaptive(0xB22D47, 0xFF9EAC)
    static let border = adaptive(0xD9DDE8, 0x353B4A)
    static let disabled = adaptive(0x72798A, 0x8D95A9)
    // Compatibility aliases for independently developed tools.
    static let key = raised
    static let ink = text
    static let secondary = muted
    static let healthy = success
    static let spacing: CGFloat = 16
    static let gutter: CGFloat = 24
    static let radius: CGFloat = 24
    static let target: CGFloat = 56
    static let title = Font.largeTitle.weight(.bold)
    static let metadata = Font.subheadline
    static let label = Font.caption.weight(.semibold)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct ScreenBody<Content: View>: View {
    var spacing: CGFloat = RemoteTheme.spacing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing, content: { content })
                .padding(.horizontal, RemoteTheme.gutter)
                .padding(.vertical, RemoteTheme.spacing)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        // ScrollView normally draws through its safe-area edges. These screens
        // hide the navigation bar, so there is no bar to cover the status area.
        .clipped()
        .background(RemoteTheme.canvas.ignoresSafeArea())
        .foregroundStyle(RemoteTheme.ink)
    }
}

/// Keeps primary actions out of scrolling content and above the native tab bar.
/// The system supplies the bar's inset; no device-specific bar height is assumed.
struct ScreenActions<Actions: View>: ViewModifier {
    var isPresented = true
    @ViewBuilder var actions: Actions

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isPresented {
                VStack(spacing: 8) { actions }
                    .padding(.horizontal, RemoteTheme.gutter)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background(RemoteTheme.canvas)
            }
        }
    }
}

struct ScreenHeading: View {
    let eyebrow: String
    let title: String
    let summary: String?

    init(_ eyebrow: String, _ title: String, _ summary: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.summary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(RemoteTheme.title).accessibilityAddTraits(.isHeader)
            if let summary {
                Text(summary).font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: { content })
            .padding(RemoteTheme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: RemoteTheme.radius))
    }
}

struct DetailRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    let detail: String
    var trailing: String? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { iconView; Spacer(); accessory }
                    labels
                }
            } else {
                HStack(spacing: 12) {
                    iconView
                    labels
                    accessory
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: RemoteTheme.target, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconView: some View {
        Image(systemName: icon)
            // Decorative symbols must stay inside their tile even at AX5.
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 38, height: 38)
            .background(RemoteTheme.key, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(RemoteTheme.accent)
            .accessibilityHidden(true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).foregroundStyle(RemoteTheme.ink)
            Text(detail).font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var accessory: some View {
        if let trailing {
            Image(systemName: trailing)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RemoteTheme.accent)
                .accessibilityHidden(true)
        }
    }
}

/// At accessibility sizes a switch must not compete with its label for width.
struct SettingsToggle: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(icon: icon, title: title, detail: detail).accessibilityHidden(true)
                Toggle(title, isOn: $isOn).labelsHidden()
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityLabel("\(title). \(detail)")
                    .accessibilityIdentifier(title)
            }
        } else {
            Toggle(isOn: $isOn) { DetailRow(icon: icon, title: title, detail: detail) }
        }
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: RemoteTheme.target)
            .padding(.horizontal, 12)
            .foregroundStyle(RemoteTheme.onAccent)
            .background(RemoteTheme.accent, in: RoundedRectangle(cornerRadius: 20))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.55)
            .contentShape(Rectangle())
    }
}

struct ConnectionMessage: View {
    @Environment(RemoteViewModel.self) private var connection

    var body: some View {
        if let error = connection.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.warning)
        } else if let feedback = connection.feedback {
            Label(feedback, systemImage: "checkmark.circle")
                .font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.healthy)
        }
    }
}
