// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lasso",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lasso",
            path: "Sources/Lasso"
        )
    ]
)
