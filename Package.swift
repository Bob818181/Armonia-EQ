// swift-tools-version:5.5
// Compatibile con Xcode 13.2+ (macOS Monterey). Target minimo: macOS 12.0.
import PackageDescription

let package = Package(
    name: "ArmoniaEQ",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "ArmoniaEQ", targets: ["ArmoniaEQ"]),
    ],
    targets: [
        .target(
            name: "ArmoniaDSP",
            path: "Sources/ArmoniaDSP",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "ArmoniaEQ",
            dependencies: ["ArmoniaDSP"],
            path: "Sources/ArmoniaEQ",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
