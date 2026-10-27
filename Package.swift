// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-cleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mclean", targets: ["mclean"]),
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
    ],
    targets: [
        .target(name: "CleanerCore"),
        .executableTarget(name: "mclean", dependencies: ["CleanerCore"]),
        .executableTarget(name: "MCleanApp", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
