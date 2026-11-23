// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TVVoice",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "TVVoice", targets: ["TVVoice"]),
        .library(name: "TVVoiceApple", targets: ["TVVoiceApple"]),
        .executable(name: "tvvoice", targets: ["tvvoice"]),
    ],
    targets: [
        .target(name: "TVVoice"),
        .target(name: "TVVoiceApple", dependencies: ["TVVoice"]),
        .executableTarget(name: "tvvoice", dependencies: ["TVVoice"]),
        .testTarget(name: "TVVoiceTests", dependencies: ["TVVoice"]),
    ]
)
