// swift-tools-version: 6.0
import PackageDescription

// libpq is keg-only in Homebrew. Override with LIBPQ_PREFIX for other installs.
let libpqPrefix = Context.environment["LIBPQ_PREFIX"] ?? "/opt/homebrew/opt/libpq"

let package = Package(
    name: "DBJoy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DBJoy", targets: ["DBJoy"]),
        .executable(name: "dbjoy-askpass", targets: ["AskPass"]),
        .executable(name: "dbjoy-mcp", targets: ["MCPBridge"]),
    ],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "Sources/CLibPQ"),
        .target(name: "DBCore"),
        .target(
            name: "PostgresDriver",
            dependencies: ["DBCore", "CLibPQ"],
            linkerSettings: [.unsafeFlags(["-L\(libpqPrefix)/lib"])]
        ),
        .executableTarget(
            name: "DBJoy",
            dependencies: ["DBCore", "PostgresDriver"]
        ),
        .executableTarget(name: "AskPass"),
        .executableTarget(name: "MCPBridge"),
        .testTarget(name: "DBCoreTests", dependencies: ["DBCore"]),
        .testTarget(name: "PostgresDriverTests", dependencies: ["PostgresDriver", "DBCore"]),
        .testTarget(name: "DBJoyTests", dependencies: ["DBJoy", "DBCore", "PostgresDriver"]),
    ]
)
