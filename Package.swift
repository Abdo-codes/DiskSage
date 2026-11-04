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
    targets: [
        .executableTarget(name: "DiskSage"),
        .testTarget(name: "DiskSageTests", dependencies: ["DiskSage"])
    ],
    swiftLanguageModes: [.v5]
)
