// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacYTDL",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacYTDL",
            path: "Sources/MacYTDL"
        )
    ]
)
