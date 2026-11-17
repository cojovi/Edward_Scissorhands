// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdwardScissorhands",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdwardScissorhands", targets: ["EdwardApp"]),
        .executable(name: "EdwardMediaWorker", targets: ["EdwardMediaWorker"]),
        .library(name: "EdwardDomain", targets: ["EdwardDomain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "EdwardDomain"),
        .target(name: "EdwardMedia", dependencies: ["EdwardDomain", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "WhisperKit")], exclude: ["Worker"]),
        .executableTarget(name: "EdwardMediaWorker", dependencies: ["EdwardMedia"], path: "Sources/EdwardMedia/Worker"),
        .target(name: "EdwardProviders", dependencies: ["EdwardDomain"]),
        .target(name: "EdwardPersistence", dependencies: ["EdwardDomain", "CSQLite"]),
        .target(name: "EdwardJobs", dependencies: ["EdwardDomain", "EdwardMedia", "EdwardProviders", "EdwardPersistence"]),
        .executableTarget(name: "EdwardApp", dependencies: ["EdwardDomain", "EdwardMedia", "EdwardProviders", "EdwardPersistence", "EdwardJobs"], resources: [.process("Resources")]),
        .testTarget(name: "EdwardTests", dependencies: ["EdwardDomain", "EdwardMedia", "EdwardProviders", "EdwardPersistence", "EdwardJobs"]),
    ],
    swiftLanguageModes: [.v5]
)
