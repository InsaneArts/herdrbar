// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Herdrbar",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The cards' glow. Its shaders load from Aurora_Aurora.bundle, which Scripts/package_app.sh copies
        // into Contents/Resources.
        .package(url: "https://github.com/tornikegomareli/Aurora.git", from: "0.5.2"),
        // Updates. Scripts/package_app.sh embeds Sparkle.framework and signs its helpers.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
    ],
    targets: [
        // Resources are copied into the .app by Scripts/package_app.sh, so the target has no Bundle.module.
        .executableTarget(name: "Herdrbar", dependencies: ["Aurora", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Herdrbar", exclude: ["Resources"]),
        .testTarget(
            name: "HerdrbarTests",
            dependencies: ["Herdrbar"],
            path: "Tests/HerdrbarTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
