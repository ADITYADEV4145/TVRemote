import SwiftUI
import UIKit

enum RemoteTheme {
    static let canvas = adaptive(0xF2F5FA, 0x0D111A)
    static let surface = adaptive(0xFFFFFF, 0x171F2E)
    static let key = adaptive(0xE9EEF8, 0x253249)
    static let ink = adaptive(0x101A2C, 0xF1F5FF)
    static let secondary = adaptive(0x475773, 0xABBBD5)
    static let accent = adaptive(0x254DB7, 0xA8BEFF)
    static let onAccent = adaptive(0xFFFFFF, 0x10214B)
    static let healthy = adaptive(0x196445, 0x78DDB0)
    static let warning = adaptive(0x93432D, 0xFFAF96)
    static let spacing: CGFloat = 16
    static let gutter: CGFloat = 20
    static let radius: CGFloat = 24
    static let target: CGFloat = 48
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
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RemoteTheme.spacing, content: { content })
                .padding(.horizontal, RemoteTheme.gutter)
                .padding(.vertical, RemoteTheme.spacing)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RemoteTheme.canvas.ignoresSafeArea())
        .foregroundStyle(RemoteTheme.ink)
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
            Text(eyebrow.uppercased())
                .font(RemoteTheme.label).tracking(2).foregroundStyle(RemoteTheme.accent)
                .accessibilityHidden(true)
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
    let icon: String
    let title: String
    let detail: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(RemoteTheme.key, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(RemoteTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(RemoteTheme.ink)
                Text(detail).font(RemoteTheme.metadata).foregroundStyle(RemoteTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Image(systemName: trailing)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RemoteTheme.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: RemoteTheme.target)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
            .background(RemoteTheme.accent, in: RoundedRectangle(cornerRadius: 15))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.55)
            .contentShape(Rectangle())
    }
}

struct ConnectionMessage: View {
    @Environment(ConnectionManager.self) private var connection

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
