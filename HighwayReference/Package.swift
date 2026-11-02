// swift-tools-version: 6.3

// MARK: - BEGIN exact copy of the main package's Package.swift
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
        .treatAllWarnings(as: .error),
    ]
}
// MARK: - END exact copy of the main package's Package.swift

// MARK: - Add reference stuff now

package.targets += [
    .target(
        name: "CHighway",
        path: "CHighway",
        publicHeadersPath: "include"
    ),
    .target(
        name: "CHighwayReference",
        dependencies: ["CHighway", "CVectorizationOps"],
        path: "CHighwayReference",
        publicHeadersPath: "include"
    ),
    .testTarget(
        name: "HighwayReferenceTests",
        dependencies: ["CHighwayReference", "HighwayReferenceCodegen", "Vectorization"],
        path: "HighwayReferenceTests",
        swiftSettings: settings + [.interoperabilityMode(.Cxx)]
    ),
    .target(
        name: "HighwayReferenceCodegen",
        dependencies: ["CHighwayReference", "Vectorization"],
        path: "HighwayReferenceCodegen",
        swiftSettings: settings + [.interoperabilityMode(.Cxx)]
    ),
]

package.cxxLanguageStandard = .cxx17
