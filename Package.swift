// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swift-adb",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ADB", targets: ["ADB"]),
        .executable(name: "swift-adb", targets: ["swift-adb"]),
    ],
    targets: [
        .target(
            name: "ADB",
            path: "Sources/ADB"
        ),
        .executableTarget(
            name: "swift-adb",
            dependencies: ["ADB"],
            path: "Sources/swift-adb"
        ),
    ]
)
