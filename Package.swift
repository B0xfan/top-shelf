// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TopShelf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TopShelf", path: "Sources/TopShelf",
                          // the self-test and picture harness exists in debug builds only
                          swiftSettings: [.define("TESTHARNESS", .when(configuration: .debug))])
    ]
)
