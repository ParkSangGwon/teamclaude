// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeamClaudeBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TeamClaudeBar", targets: ["TeamClaudeBar"]),
        .library(name: "TeamClaudeCore", targets: ["TeamClaudeCore"]),
    ],
    targets: [
        .target(name: "TeamClaudeCore", resources: [.process("Resources")]),
        .executableTarget(name: "TeamClaudeBar", dependencies: ["TeamClaudeCore"]),
        .testTarget(name: "TeamClaudeCoreTests", dependencies: ["TeamClaudeCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
