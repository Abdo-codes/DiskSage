// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DiskSage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DiskSage", targets: ["DiskSage"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.26.2")
    ],
    targets: [
        .executableTarget(name: "DiskSage", dependencies: [
            .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
        ]),
        .testTarget(name: "DiskSageTests", dependencies: ["DiskSage"])
    ],
    swiftLanguageModes: [.v5]
)
