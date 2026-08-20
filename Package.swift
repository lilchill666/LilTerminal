// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LilTerminal",
    platforms: [.macOS(.v14)],
    targets: [
        // Ghostty's VT engine, vendored as a static library. See
        // Vendor/ghostty-vt/REVISION and Tools/build-ghostty-vt.sh.
        .systemLibrary(name: "CGhosttyVT", path: "Sources/CGhosttyVT"),

        // Shared by the app and the session daemon: the daemon owns the ptys,
        // so the pty code cannot live inside the app target.
        .target(name: "TerminalCore", path: "Sources/TerminalCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // Outlives the app so shells survive a quit or a crash.
        .executableTarget(name: "lilterm-sessiond",
                          dependencies: ["TerminalCore"],
                          path: "Sources/lilterm-sessiond",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "LilTerminal",
            dependencies: ["CGhosttyVT", "TerminalCore"],
            path: "Sources/LilTerminal",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-I", "Vendor/ghostty-vt/include"]),
            ],
            linkerSettings: [
                // Dynamic, not static: Zig bundles its own compiler-rt, whose
                // ___isPlatformVersionAtLeast collides with Swift's runtime at
                // static link time. A dylib keeps the two copies apart.
                .unsafeFlags([
                    "-LVendor/ghostty-vt/lib",
                    // First rpath is the app bundle; second lets a plain
                    // `swift build` binary run from the source tree.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Vendor/ghostty-vt/lib",
                ]),
            ]
        )
    ]
)
