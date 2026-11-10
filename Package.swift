// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-vectorization",
    products: [
        .library(name: "Vectorization", targets: ["Vectorization"])
    ],
    targets: [
        .target(
            name: "CVectorizationOps",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Vectorization",
            dependencies: ["CVectorizationOps"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "VectorizationTests",
            dependencies: ["Vectorization"],
            swiftSettings: settings
        ),
    ]
)

var settings: [SwiftSetting] {
    [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableExperimentalFeature("SafeInteropWrappers"),
        .enableExperimentalFeature(
            "AvailabilityMacro=SwiftStdlib 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0"
        ),
        .enableExperimentalFeature(
            "AvailabilityMacro=SwiftStdlib 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0"
        ),
        .treatAllWarnings(as: .error),
    ]
}
