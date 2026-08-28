// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KaijuKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KaijuKit", targets: ["KaijuKit"]),
        .executable(name: "kaijuctl", targets: ["kaijuctl"])
    ],
    targets: [
        .target(
            name: "KaijuKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "kaijuctl",
            dependencies: ["KaijuKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KaijuKitTests",
            dependencies: ["KaijuKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
