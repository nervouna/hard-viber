// swift-tools-version: 6.0
import PackageDescription

// QuotaKit holds the logic and the views; Quota only starts it with Quota.app's resource directory.
// scripts/build.sh assembles the app bundle around the release binary.
let package = Package(
    name: "Quota",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "QuotaKit"),
        .executableTarget(name: "Quota", dependencies: ["QuotaKit"]),
        .testTarget(name: "QuotaKitTests", dependencies: ["QuotaKit"]),
    ]
)
