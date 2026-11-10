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
        .enableExperimentalFeature(
            "AvailabilityMacro=SwiftStdlib 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0"
        ),
        .treatAllWarnings(as: .error),
    ]
}
// MARK: - END exact copy of the main package's Package.swift

// MARK: - Add reference stuff now

let elementNames = [
    "SIMDBFloat16", "SIMDDouble", "SIMDFloat", "SIMDFloat16", "SIMDInt16", "SIMDInt32", "SIMDInt64",
    "SIMDInt8", "SIMDUInt16", "SIMDUInt32", "SIMDUInt64", "SIMDUInt8",
]

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
    .target(
        name: "HighwayReferenceTestSupport",
        dependencies: ["CHighwayReference", "Vectorization"],
        path: "HighwayReferenceTests/HighwayReferenceTestSupport",
        swiftSettings: settings + [.interoperabilityMode(.Cxx)]
    ),
    .testTarget(
        name: "HighwayTargetTests",
        dependencies: ["CHighwayReference", "HighwayReferenceTestSupport", "Vectorization"],
        path: "HighwayReferenceTests/Generated/HighwayTargetTests",
        swiftSettings: settings + [.interoperabilityMode(.Cxx)]
    ),
    .target(
        name: "HighwayReferenceCodegen",
        dependencies: ["CHighwayReference", "Vectorization"],
        path: "HighwayReferenceCodegen",
        swiftSettings: settings + [.interoperabilityMode(.Cxx)]
    ),
]

package.targets += elementNames.map { name in
    .testTarget(
        name: "\(name)Tests",
        dependencies: [
            "CHighwayReference", "HighwayReferenceCodegen", "HighwayReferenceTestSupport",
            "Vectorization",
        ],
        path: "HighwayReferenceTests/Generated/\(name)Tests",
        swiftSettings: settings + [.interoperabilityMode(.Cxx)]
    )
}

package.cxxLanguageStandard = .cxx17
