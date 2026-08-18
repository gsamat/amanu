// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "amanu",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "amanu",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Sparkle is a framework, and `make app` puts it in
            // Contents/Frameworks. SwiftPM builds a bare executable and has no
            // idea a bundle is coming, so the search path it would need at
            // runtime has to be stated here.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "amanuTests",
            dependencies: ["amanu"]
        ),
    ]
)
