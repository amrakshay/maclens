// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacLens", targets: ["MacLens"]),
    ],
    targets: [
        .target(
            name: "MacLensCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(name: "MacLens", dependencies: ["MacLensCore"]),
        .executableTarget(name: "maclens-selftest", dependencies: ["MacLensCore"], path: "Sources/SelfTest"),
    ]
)
