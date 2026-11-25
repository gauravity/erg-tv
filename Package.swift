// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RideScreen",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "RideScreen", targets: ["RideScreen"])],
    targets: [
        .target(name: "RideCore"),
        .target(name: "RideBluetooth", dependencies: ["RideCore"]),
        .executableTarget(
            name: "RideScreen",
            dependencies: ["RideCore", "RideBluetooth"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "RideCoreTests", dependencies: ["RideCore"]),
        .testTarget(name: "RideBluetoothTests", dependencies: ["RideBluetooth"]),
    ],
    swiftLanguageModes: [.v5]
)
