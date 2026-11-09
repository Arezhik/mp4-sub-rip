// swift-tools-version:5.9
import PackageDescription

// The exception box is Objective-C. The manifest is evaluated on the host, so
// Linux `swift test` never sees the target. macOS builds it for the caption
// adaptor spike, which has to catch NSException and keep ffmpeg as the writer.
let captionExceptionBox: [Target] = {
    #if os(macOS)
    return [
        .target(
            name: "CaptionExceptionBox",
            path: "Sources/CaptionExceptionBox",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        )
    ]
    #else
    return []
    #endif
}()

let coreDependencies: [Target.Dependency] = {
    #if os(macOS)
    return ["CaptionExceptionBox"]
    #else
    return []
    #endif
}()

let package = Package(
    // Not "MP4SubRip". That is the Xcode project's name, and the IDE drops the
    // products when the package and the project share a name and a folder.
    name: "MP4SubRipKit",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "MP4SubRipCore", targets: ["MP4SubRipCore"])
    ],
    targets: [
        // Core logic only: no AppKit, SwiftUI, or Vision imports, so `swift test`
        // runs on Linux (cloud agents and the Linux CI job) as well as on a Mac.
        .target(name: "MP4SubRipCore", dependencies: coreDependencies),
        .testTarget(name: "MP4SubRipCoreTests", dependencies: ["MP4SubRipCore"])
    ] + captionExceptionBox
)
