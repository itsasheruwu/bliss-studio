// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BlissStudio",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .target(name: "BlissAudio", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BlissStudio", dependencies: ["BlissAudio", "Yams", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Resources/StudioMaps"), .copy("Resources/StudioStickers")],
                          swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
