// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-browser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "agent-browser", path: "Sources/agent-browser")
    ]
)
