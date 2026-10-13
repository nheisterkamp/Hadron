// swift-tools-version: 6.2
import Foundation
import PackageDescription
let testsPath = "Tests/HadronAppTests"
let payloadPath = "Sources/HadronApp/Resources/payload"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasTests = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(testsPath).path)

// make app-payload stages the payload, so a checkout that has not been built does
// not have it. A declared resource that is missing is a build error, while an app
// missing the payload is a condition InstallPayload already reports.
let hasPayload = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(payloadPath).path)
let package = Package(
    name: "HadronApp",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "HadronApp",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/HadronApp",
            resources: (hasPayload ? [.copy("Resources/payload")] : []) + [
                .process("Resources/Localization"),
                .copy("Resources/payload.manifest"),
                .copy("Resources/valve-packages.manifest"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + (hasTests ? [
        .testTarget(
            name: "HadronAppTests",
            dependencies: ["HadronApp"],
            path: testsPath
        ),
    ] : [])
)
