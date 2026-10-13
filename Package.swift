// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunXcodeApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RunXcodeApp",
            path: "Sources/RunXcodeApp"
        )
    ]
)
