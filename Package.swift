// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NovaContext",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "NovaContext", targets: ["NovaContext"])],
    dependencies: [.package(url: "https://github.com/rhindsntc/NovaGraph.git", exact: "1.0.0")],
    targets: [
        .target(name: "NovaContext", dependencies: [.product(name: "GraphDBKit", package: "novagraph")]),
        .testTarget(name: "NovaContextTests", dependencies: ["NovaContext", .product(name: "GraphDBKit", package: "novagraph")])
    ]
)
