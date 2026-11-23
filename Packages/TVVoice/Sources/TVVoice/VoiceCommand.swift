import Foundation

/// A remote button the voice layer can press. The app maps each case onto the
/// driver package's own key type.
public enum VoiceKey: String, CaseIterable, Sendable, Codable {
    case home, back, up, down, left, right, select
    case menu, info, settings, search
    case play, pause, playPause, stop, rewind, fastForward, next, previous, replay
    case captions
}

public enum VolumeAction: Equatable, Sendable {
    case up(Int)
    case down(Int)
    case set(Int)
    case mute
    case unmute
}

public enum PowerAction: String, Equatable, Sendable {
    case on, off, toggle
}

public enum ChannelAction: Equatable, Sendable {
    /// A channel number as spoken, e.g. "7" or "7.1".
    case number(String)
    case up
    case down
    case previous
}

public enum InputSource: Equatable, Sendable {
    case hdmi(Int)
    case tuner
    case next
}

/// What the user asked the TV to do, independent of any TV platform.
public enum VoiceCommand: Equatable, Sendable {
    case key(VoiceKey, times: Int = 1)
    case volume(VolumeAction)
    case power(PowerAction)
    case channel(ChannelAction)
    case launch(AppID)
    /// Content search, handed to the TV's own search where the platform has one.
    case search(query: String, app: AppID? = nil)
    /// Jump within playback; negative seconds go back.
    case seek(seconds: Int)
    case input(InputSource)
    /// Type text into the TV's focused text field.
    case type(String)
}

extension VoiceCommand {
    /// A stable, compact form used by the golden set and logs, e.g. `key:down*3`,
    /// `volume:up:2`, `launch:netflix`, `search:severance@apple-tv`.
    public var canonical: String {
        switch self {
        case let .key(key, times):
            return times == 1 ? "key:\(key.rawValue)" : "key:\(key.rawValue)*\(times)"
        case let .volume(action):
            switch action {
            case let .up(n): return "volume:up:\(n)"
            case let .down(n): return "volume:down:\(n)"
            case let .set(n): return "volume:set:\(n)"
            case .mute: return "volume:mute"
            case .unmute: return "volume:unmute"
            }
        case let .power(action):
            return "power:\(action.rawValue)"
        case let .channel(action):
            switch action {
            case let .number(n): return "channel:\(n)"
            case .up: return "channel:up"
            case .down: return "channel:down"
            case .previous: return "channel:previous"
            }
        case let .launch(app):
            return "launch:\(app.rawValue)"
        case let .search(query, app):
            return app.map { "search:\(query)@\($0.rawValue)" } ?? "search:\(query)"
        case let .seek(seconds):
            return "seek:\(seconds)"
        case let .input(source):
            switch source {
            case let .hdmi(n): return "input:hdmi\(n)"
            case .tuner: return "input:tuner"
            case .next: return "input:next"
            }
        case let .type(text):
            return "type:\(text)"
        }
    }

    /// The one-line confirmation shown after the command runs ("Opening Netflix").
    public func confirmation(catalog: AppCatalog = .standard) -> String {
        func appName(_ id: AppID) -> String { catalog.entry(for: id)?.name ?? id.rawValue }
        switch self {
        case let .key(key, times):
            let base: String
            switch key {
            case .home: base = "Going home"
            case .back: base = "Going back"
            case .up: base = "Up"
            case .down: base = "Down"
            case .left: base = "Left"
            case .right: base = "Right"
            case .select: base = "Selecting"
            case .menu: base = "Options"
            case .info: base = "Info"
            case .settings: base = "Opening settings"
            case .search: base = "Opening search"
            case .play: base = "Playing"
            case .pause: base = "Pausing"
            case .playPause: base = "Play/pause"
            case .stop: base = "Stopping"
            case .rewind: base = "Rewinding"
            case .fastForward: base = "Fast-forwarding"
            case .next: base = "Next"
            case .previous: base = "Previous"
            case .replay: base = "Replaying"
            case .captions: base = "Toggling captions"
            }
            return times > 1 ? "\(base) ×\(times)" : base
        case let .volume(action):
            switch action {
            case let .up(n): return n > 1 ? "Volume up \(n)" : "Volume up"
            case let .down(n): return n > 1 ? "Volume down \(n)" : "Volume down"
            case let .set(n): return "Volume \(n)"
            case .mute: return "Muted"
            case .unmute: return "Sound on"
            }
        case let .power(action):
            switch action {
            case .on: return "Turning TV on"
            case .off: return "Turning TV off"
            case .toggle: return "Power"
            }
        case let .channel(action):
            switch action {
            case let .number(n): return "Channel \(n)"
            case .up: return "Channel up"
            case .down: return "Channel down"
            case .previous: return "Previous channel"
            }
        case let .launch(app):
            return "Opening \(appName(app))"
        case let .search(query, app):
            let title = query.capitalizedWords
            return app.map { "Searching \(appName($0)) for \(title)" } ?? "Searching for \(title)"
        case let .seek(seconds):
            return seconds < 0 ? "Back \(-seconds)s" : "Forward \(seconds)s"
        case let .input(source):
            switch source {
            case let .hdmi(n): return "HDMI \(n)"
            case .tuner: return "Antenna"
            case .next: return "Next input"
            }
        case let .type(text):
            return "Typing “\(text)”"
        }
    }
}

/// The voice layer's answer to one utterance.
public enum VoiceInterpretation: Equatable, Sendable {
    case command(VoiceCommand)
    /// Ambiguous: ask one short question instead of guessing.
    case clarify(question: String, options: [VoiceCommand])
    case unrecognized

    public var canonical: String {
        switch self {
        case let .command(c): return c.canonical
        case let .clarify(_, options): return "clarify:" + options.map(\.canonical).joined(separator: "|")
        case .unrecognized: return "none"
        }
    }
}

extension String {
    var capitalizedWords: String {
        split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
