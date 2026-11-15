// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ListenTogether",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ListenTogether",
            path: "Sources/ListenTogether"
        ),
        .testTarget(
            name: "ListenTogetherTests",
            dependencies: ["ListenTogether"],
            path: "Tests/ListenTogetherTests"
        ),
    ]
)
