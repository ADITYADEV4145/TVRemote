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
        .target(name: "SamsungDriver", dependencies: ["TVRemoteCore"]),
        .target(name: "LGDriver", dependencies: ["TVRemoteCore"]),
        .target(name: "TVRemoteKit", dependencies: ["TVRemoteCore", "RokuDriver", "GoogleTVDriver", "SamsungDriver", "LGDriver"]),
        .testTarget(name: "TVRemoteKitTests", dependencies: ["TVRemoteKit"])
    ]
)
