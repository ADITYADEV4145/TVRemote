import SwiftUI
import TVDriverKit

struct ScenesScreen: View {
    @AppStorage("sceneDraftName") private var name = ""
    @AppStorage("sceneDraftSteps") private var encoded = ""

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Scenes", "A few actions. One familiar routine.")
            HeroCard(icon: "square.stack", title: "Make a scene draft",
                     detail: "Plan a sequence of supported remote actions. Running scenes is not connected in this build.")
            if !name.isEmpty {
                NavigationLink {
                    SceneReviewScreen(name: name, steps: SceneStep.decode(encoded))
                } label: {
                    Panel { DetailRow(icon: "play.rectangle", title: name, detail: "Saved draft · \(SceneStep.decode(encoded).count) steps", trailing: "chevron.right") }
                }.buttonStyle(.plain)
            }
            NavigationLink(name.isEmpty ? "Create a draft" : "Edit draft") { SceneEditorScreen() }
                .buttonStyle(PrimaryActionStyle())
            SupportingCopy(title: "Review before running", detail: "Future scene execution must use an explicit TV, stop at the first failure and never replay unsent actions without review.")
        }.modifier(TaskSurface())
    }
}

enum SceneStep: String, CaseIterable, Identifiable {
    case home, volumeDown, playPause
    var id: String { rawValue }
    var title: String {
        switch self { case .home: "Go Home"; case .volumeDown: "Volume down"; case .playPause: "Play or pause" }
    }
    var symbol: String {
        switch self { case .home: "house"; case .volumeDown: "speaker.minus"; case .playPause: "playpause" }
    }
    static func decode(_ encoded: String) -> [Self] { encoded.split(separator: ",").compactMap { Self(rawValue: String($0)) } }
}

struct SceneEditorScreen: View {
    @AppStorage("sceneDraftName") private var savedName = ""
    @AppStorage("sceneDraftSteps") private var savedSteps = ""
    @State private var name = ""
    @State private var steps: [SceneStep] = []
    @State private var loadedDraft = false
    @Environment(\.dismiss) private var dismiss
    var sample = false

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Create a scene", "Draft only · No TV commands will run.")
            TextField("Scene name", text: $name).padding(16)
                .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            Text("Steps").font(.title3.weight(.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Panel {
                    DetailRow(icon: step.symbol, title: "\(index + 1). \(step.title)", detail: "Driver support required")
                    HStack {
                        Button("Move up", systemImage: "arrow.up") { move(index, by: -1) }
                            .disabled(index == 0).labelStyle(.iconOnly).frame(width: 44, height: 44)
                        Button("Move down", systemImage: "arrow.down") { move(index, by: 1) }
                            .disabled(index == steps.count - 1).labelStyle(.iconOnly).frame(width: 44, height: 44)
                        Spacer()
                        Button("Remove step", systemImage: "trash", role: .destructive) { steps.remove(at: index) }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }
                }
                .accessibilityAction(named: "Move up") { move(index, by: -1) }
                .accessibilityAction(named: "Move down") { move(index, by: 1) }
            }
            Menu("Add a step", systemImage: "plus") {
                ForEach(SceneStep.allCases) { step in Button(step.title) { steps.append(step) } }
            }.buttonStyle(SecondaryActionStyle())
            NavigationLink("Review draft") { SceneReviewScreen(name: name, steps: steps) }
                .buttonStyle(SecondaryActionStyle()).disabled(steps.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Save draft") {
                savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                savedSteps = steps.map(\.rawValue).joined(separator: ",")
                dismiss()
            }.buttonStyle(PrimaryActionStyle()).disabled(steps.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sample)
        }
        .modifier(TaskSurface())
        .onAppear {
            guard !loadedDraft else { return }
            loadedDraft = true
            name = sample ? "Movie night" : savedName
            steps = sample ? [.home, .volumeDown, .playPause] : SceneStep.decode(savedSteps)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        guard steps.indices.contains(index), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
    }
}

struct SceneReviewScreen: View {
    var name = "Movie night"
    var steps: [SceneStep] = [.home, .volumeDown, .playPause]
    var resultPreview = false

    var body: some View {
        ScreenBody {
            ScreenHeading("", resultPreview ? "Scene paused" : "Review your scene", name)
            SupportingCopy(title: resultPreview ? "Nothing will resume automatically" : "Choose a TV before running",
                           detail: resultPreview ? "This presentation shows a failure partway through. Review unsent steps before any future retry."
                           : "The execution service is not connected. Saving or reviewing a draft does not send commands.")
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Panel {
                    DetailRow(icon: resultPreview && index == 0 ? "checkmark.circle" : step.symbol,
                              title: "\(index + 1). \(step.title)",
                              detail: resultPreview ? (index == 0 ? "Acknowledged" : index == 1 ? "Failed · Connection lost" : "Not sent") : "Not sent")
                }
            }
            Button("Run unavailable") {}.buttonStyle(PrimaryActionStyle()).disabled(true)
            SupportingCopy(title: "Free controls remain available", detail: "Return to Remote to use individual supported actions.")
        }.modifier(TaskSurface())
    }
}
