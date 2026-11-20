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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "GmailPingCore",
            dependencies: [],
            path: "Sources/GmailPingCore"
        ),
        .executableTarget(
            name: "GmailPingApp",
            dependencies: ["GmailPingCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/GmailPingApp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "GmailPingTests",
            dependencies: ["GmailPingCore"],
            path: "Tests/GmailPingTests"
        )
    ]
)
