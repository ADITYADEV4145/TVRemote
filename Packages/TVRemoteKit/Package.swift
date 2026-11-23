// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVRemoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TVRemoteKit", targets: ["TVRemoteKit"])],
    targets: [
        .target(name: "TVRemoteCore"),
        .target(name: "RokuDriver", dependencies: ["TVRemoteCore"]),
        .target(name: "GoogleTVDriver", dependencies: ["TVRemoteCore"]),
        .target(name: "TVRemoteKit", dependencies: ["TVRemoteCore", "RokuDriver", "GoogleTVDriver"]),
        .testTarget(name: "TVRemoteKitTests", dependencies: ["TVRemoteKit"])
    ]
)
