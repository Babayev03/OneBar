// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneBar",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "OneBar",
            path: "Sources/OneBar",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "OneBarTests",
            dependencies: ["OneBar"],
            path: "Tests/OneBarTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
