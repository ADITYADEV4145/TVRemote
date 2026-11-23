#if DEBUG
import SwiftUI
import TVDriverKit

/// One entry per iPhone screen/state in the Figma handoff. These are view fixtures,
/// not simulated permission grants, purchases or voice recognition.
enum DesignSpec: String, CaseIterable, Identifiable {
    case welcome = "Welcome", network = "Network permission", find = "Find TVs"
    case code = "Pair code", approval = "Pair approval", pairError = "Pair error", ready = "Pair ready"
    case manual = "Manual IP", denied = "Network denied", noTVs = "No TVs found", compatibility = "Compatibility"
    case remote = "Remote", connecting = "Connecting", recovering = "Recovering", sleep = "Sleep", repair = "Repair"
    case touchpad = "Touchpad", inputs = "Inputs", diagnostics = "Diagnostics", connection = "Connection details"
    case support = "Support preview", keypad = "Keypad"
    case myTVs = "My TVs", tvDetails = "TV details", forget = "Forget TV", apps = "Apps", favorites = "Edit favorites"
    case appsUnavailable = "Apps unavailable", keyboard = "Keyboard", textSent = "Text sent"
    case voice = "Voice", listening = "Voice listening", voiceResult = "Voice result", clarify = "Voice clarify", voiceUnavailable = "Voice unavailable"
    case settings = "Settings", appearance = "Appearance", voiceSettings = "Voice settings", privacy = "Privacy", plus = "Plus"
    case pending = "Purchase pending", purchaseError = "Purchase error", restore = "Restore", restoreEmpty = "Restore empty"
    case scenes = "Scenes", sceneEditor = "Scene editor", scenePreview = "Scene preview", sceneResult = "Scene result", shortcuts = "Shortcuts"
    case voicePermission = "Voice permission", voiceRetry = "Voice retry", plusActive = "Plus active", unavailable = "Capability unavailable"
    case largeControls = "Large controls", largeSetup = "Large text setup"
    var id: String { rawValue }
    var slug: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "-") }
}

struct DesignCatalogScreen: View {
    @State private var selected: DesignSpec?
    var body: some View {
        List {
            Section {
                Text("55 iPhone states · Light & Dark").font(.headline)
                Text("Presentation fixtures only. Permission, voice, commerce and scene results are not live service results.")
                    .foregroundStyle(RemoteTheme.muted)
            }
            ForEach(DesignSpec.allCases) { spec in
                Button(spec.rawValue) { selected = spec }.frame(minHeight: 44)
            }
        }
        .navigationTitle("Design states")
        .modifier(TaskSurface())
        .fullScreenCover(item: $selected) { DesignStateHost(spec: $0) }
    }
}

struct DesignStateHost: View {
    let spec: DesignSpec
    @State private var connection = ConnectionManager(driver: MockTVDriver(), isDemo: true)
    @State private var prepared = false
    @State private var favorites = "netflix,youtube,prime-video"
    @Environment(\.dismiss) private var dismiss
    var appearance: ColorScheme? = nil

    var body: some View {
        Group {
            if prepared {
                content.accessibilityIdentifier("designReady")
            } else {
                ProgressView("Preparing design fixture").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(connection)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("DESIGN PREVIEW · \(spec.rawValue)").font(.caption2.weight(.semibold))
                Spacer()
                Button("Close preview", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            .padding(.horizontal, 24).background(RemoteTheme.accentSoft)
        }
        .preferredColorScheme(appearance)
        .tint(RemoteTheme.accent)
        .background(RemoteTheme.canvas)
        .task {
            await connection.prepareDesignPreview(state: state, pairing: spec == .code || spec == .pairError)
            prepared = true
        }
    }

    @ViewBuilder private var content: some View {
        switch spec {
        case .remote, .connecting, .recovering, .sleep, .repair, .touchpad, .largeControls:
            RootScreen(showWelcome: false, remoteTouchpad: spec == .touchpad, forceLarge: spec == .largeControls)
        case .apps: RootScreen(initialTab: .apps, showWelcome: false)
        case .myTVs: RootScreen(initialTab: .devices, showWelcome: false)
        case .settings: RootScreen(initialTab: .settings, showWelcome: false)
        default:
            NavigationStack { taskContent }
        }
    }

    @ViewBuilder private var taskContent: some View {
        switch spec {
        case .welcome, .network, .find, .code, .ready, .manual, .largeSetup:
            SetupScreen(initialPage: setupPage) {}
                .dynamicTypeSize(spec == .largeSetup ? .accessibility3 : .large)
        case .approval, .pairError, .denied, .noTVs:
            ScreenBody { SetupStatusContent(page: setupPage) }.modifier(CloseTool())
        case .compatibility: CompatibilityScreen()
        case .inputs: InputsScreen()
        case .diagnostics: DiagnosticsScreen()
        case .connection: ConnectionDetailsScreen()
        case .support: SupportPreviewScreen()
        case .keypad: KeypadScreen()
        case .tvDetails: TVDetailScreen(device: MockTVDriver.devices[0])
        case .forget: ForgetTVScreen(device: MockTVDriver.devices[0])
        case .favorites: FavoritesScreen(favorites: $favorites, catalog: RemoteAppItem.demo)
        case .appsUnavailable: AppsScreen(forceUnavailable: true, setup: {})
        case .keyboard: KeyboardScreen()
        case .textSent: KeyboardScreen(sentPreview: true)
        case .voice: VoiceScreen(phase: .introduction)
        case .listening: VoiceScreen(phase: .listening)
        case .voiceResult: VoiceScreen(phase: .result)
        case .clarify: VoiceScreen(phase: .clarify)
        case .voiceUnavailable: VoiceScreen()
        case .voicePermission: VoiceScreen(phase: .permission)
        case .voiceRetry: VoiceScreen(phase: .retry)
        case .appearance: AppearanceScreen()
        case .voiceSettings: VoiceSettingsScreen()
        case .privacy: PrivacyScreen()
        case .plus: UpgradeScreen()
        case .pending: UpgradeScreen(phase: .pending)
        case .purchaseError: UpgradeScreen(phase: .failed)
        case .restore: UpgradeScreen(phase: .restore)
        case .restoreEmpty: UpgradeScreen(phase: .empty)
        case .plusActive: UpgradeScreen(phase: .active)
        case .scenes: ScenesScreen()
        case .sceneEditor: SceneEditorScreen(sample: true)
        case .scenePreview: SceneReviewScreen()
        case .sceneResult: SceneReviewScreen(resultPreview: true)
        case .shortcuts: ShortcutsScreen()
        case .unavailable:
            UnavailableScreen(title: "Action unavailable", icon: "hand.raised",
                              reason: "The connected driver does not support this action. Keep using the supported remote buttons.")
        default: EmptyView()
        }
    }

    private var state: ConnectionState {
        switch spec {
        case .connecting: .connecting
        case .recovering: .recovering
        case .sleep: .asleep
        case .repair: .needsRepair
        default: .ready
        }
    }
    private var setupPage: SetupPage {
        switch spec {
        case .network, .largeSetup: .network
        case .find: .discovery
        case .code: .code
        case .approval: .approval
        case .pairError: .retry
        case .ready: .ready
        case .manual: .manual
        case .denied: .denied
        case .noTVs: .empty
        default: .welcome
        }
    }
}
#endif
