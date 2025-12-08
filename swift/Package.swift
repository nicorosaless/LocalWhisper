// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WhisperMac", targets: ["WhisperMac"])
    ],
    targets: [
        .executableTarget(
            name: "WhisperMac",
            path: "Sources"
        )
    ]
)
