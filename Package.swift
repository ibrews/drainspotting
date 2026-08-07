// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Drainspotting",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DrainspottingKit", targets: ["DrainspottingKit"]),
        .executable(name: "drainspot", targets: ["drainspot"]),
    ],
    targets: [
        .target(name: "DrainspottingKit"),
        .executableTarget(name: "drainspot", dependencies: ["DrainspottingKit"]),
        .testTarget(
            name: "DrainspottingKitTests",
            dependencies: ["DrainspottingKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
