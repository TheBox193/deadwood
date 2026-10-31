// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Deadwood",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "Deadwood", path: "Sources/Deadwood", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "DeadwoodTests", dependencies: ["Deadwood"], path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
