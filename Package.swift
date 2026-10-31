// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sing",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "sing", targets: ["sing"])],
    targets: [
        .target(name: "SingCore"),
        .executableTarget(name: "sing", dependencies: ["SingCore"]),
        .testTarget(name: "SingCoreTests", dependencies: ["SingCore"]),
    ]
)
