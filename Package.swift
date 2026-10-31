// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "WorktreeSweeper",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "WorktreeSweeper", path: "Sources/WorktreeSweeper", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "WorktreeSweeperTests", dependencies: ["WorktreeSweeper"], path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
