// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VSCodeSwitcher",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "VSCodeSwitcher",
            path: "Sources/VSCodeSwitcher"
        ),
        .testTarget(
            name: "VSCodeSwitcherTests",
            dependencies: ["VSCodeSwitcher"],
            path: "Tests/VSCodeSwitcherTests"
        )
    ]
)
