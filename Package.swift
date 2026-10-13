// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeuEQ",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "MeuEQ")
    ]
)
