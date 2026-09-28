// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Herdrbar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Herdrbar", path: "Sources/Herdrbar"),
        .testTarget(
            name: "HerdrbarTests",
            dependencies: ["Herdrbar"],
            path: "Tests/HerdrbarTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
