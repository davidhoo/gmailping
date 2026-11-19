// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GmailPing",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GmailPingCore",
            targets: ["GmailPingCore"]
        ),
        .executable(
            name: "GmailPingApp",
            targets: ["GmailPingApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GmailPingCore",
            dependencies: [],
            path: "Sources/GmailPingCore"
        ),
        .executableTarget(
            name: "GmailPingApp",
            dependencies: ["GmailPingCore"],
            path: "Sources/GmailPingApp"
        ),
        .testTarget(
            name: "GmailPingTests",
            dependencies: ["GmailPingCore"],
            path: "Tests/GmailPingTests"
        )
    ]
)
