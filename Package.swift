// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Herdrbar",
    platforms: [.macOS(.v15)],
    targets: [
        // Resources are copied into the .app by Scripts/package_app.sh, so the target has no Bundle.module.
        .executableTarget(name: "Herdrbar", path: "Sources/Herdrbar", exclude: ["Resources"]),
        .testTarget(
            name: "HerdrbarTests",
            dependencies: ["Herdrbar"],
            path: "Tests/HerdrbarTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
