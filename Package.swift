// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LumaRoute", platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumaRouteCore", targets: ["LumaRouteCore"]),
        .executable(name: "LumaRoute", targets: ["LumaRoute"]),
        .executable(name: "LumaRouteHelper", targets: ["LumaRouteHelper"]),
        .executable(name: "LumaRouteCLI", targets: ["LumaRouteCLI"])
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.1.0")],
    targets: [
        .target(name: "LumaRouteCore", dependencies: [.product(name: "Yams", package: "Yams")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "LumaRoute", dependencies: ["LumaRouteCore"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "LumaRouteHelper", dependencies: ["LumaRouteCore"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "LumaRouteCLI", dependencies: ["LumaRouteCore"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LumaRouteCoreTests", dependencies: ["LumaRouteCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)

