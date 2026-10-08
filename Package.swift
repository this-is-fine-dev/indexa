// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Indexa",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Indexa", targets: ["IndexaApp"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .target(name: "IndexaCore", dependencies: [.product(name: "Vapor", package: "vapor")]),
        .executableTarget(name: "IndexaApp", dependencies: ["IndexaCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "IndexaCoreTests", dependencies: ["IndexaCore", .product(name: "VaporTesting", package: "vapor")]),
        .testTarget(name: "IndexaAppTests", dependencies: ["IndexaApp"])
    ],
    swiftLanguageModes: [.v5]
)
