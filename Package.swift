// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Squeeze",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Squeeze", targets: ["Squeeze"])],
    targets: [
        // Everything that does not need a window: Steam libraries, scanning, estimates, running afsctool.
        .target(name: "SqueezeCore"),
        // The menu bar app.
        .executableTarget(name: "Squeeze", dependencies: ["SqueezeCore"]),
        .testTarget(name: "SqueezeCoreTests", dependencies: ["SqueezeCore"]),
    ]
)
