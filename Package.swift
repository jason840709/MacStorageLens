// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MacStorageLens",
  defaultLocalization: "zh-Hant",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "MacStorageLens", targets: ["MacStorageLens"])
  ],
  targets: [
    .executableTarget(
      name: "MacStorageLens",
      path: "Sources/MacStorageLens",
      linkerSettings: [
        .linkedFramework("AppKit")
      ]
    )
  ],
  swiftLanguageVersions: [.v5]
)
