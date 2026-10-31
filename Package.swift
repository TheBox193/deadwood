// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "WorktreeSweeper",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "WorktreeSweeper", path: "Sources/WorktreeSweeper")
  ]
)
