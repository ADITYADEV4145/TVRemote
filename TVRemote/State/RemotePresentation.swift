import Foundation

struct TVDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let platform: String
    let address: String
    var requiresPairingCode = false
    var supportsPointer = false
}

enum RemoteKey: String, Equatable, Sendable {
    case power, up, down, left, right, select, back, home
    case volumeUp, volumeDown, mute, channelUp, channelDown, playPause
}

enum ConnectionState: String, Equatable, Sendable {
    case idle = "Not connected"
    case discovering = "Finding TVs"
    case connecting = "Connecting"
    case ready = "Connected"
    case degraded = "Connection interrupted"
    case asleep = "TV asleep"
    case recovering = "Reconnecting"
    case needsRepair = "Pair again"
}

enum SetupPairing: Equatable {
    case code, approval
}
