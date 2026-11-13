import Testing
import Vectorization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(ucrt)
import ucrt
#endif

private func expectedTarget() -> String? {
    #if os(Windows)
    var value: UnsafeMutablePointer<CChar>?
    guard unsafe _dupenv_s(&value, nil, "SIMD_EXPECTED_TARGET") == 0, let value = unsafe value
    else { return nil }
    defer { unsafe free(value) }
    return unsafe String(cString: value)
    #else
    unsafe getenv("SIMD_EXPECTED_TARGET").map { unsafe String(cString: $0) }
    #endif
}

private func vectorBytes<E: SIMDElement>(of type: E.Type) -> Int {
    E.laneCount * MemoryLayout<E.Lane>.size
}

@Suite("Target")
struct TargetTests {
    static let vectorBytesOfTarget: [String: Int] = [
        "EMU128": 16,
        "NEON_WITHOUT_AES": 16,
        "NEON": 16,
        "NEON_BF16": 16,
        "SVE2_128": 16,
        "SSE2": 16,
        "SSSE3": 16,
        "SSE4": 16,
        "PPC8": 16,
        "PPC9": 16,
        "PPC10": 16,
        "Z14": 16,
        "Z15": 16,
        "WASM": 16,
        "LSX": 16,
        "AVX2": 32,
        "AVX3": 64,
        "AVX3_DL": 64,
        "AVX3_ZEN4": 64,
        "AVX3_SPR": 64,
    ]

    @Test("Reports the target it was compiled for")
    func reportsTarget() {
        #expect(!SIMDTarget.targetName.isEmpty)
    }

    @Test("Compiles for exactly one target, the one it names")
    func compilesForOneTarget() {
        #expect(SIMDTarget.target.rawValue.nonzeroBitCount == 1)
        #expect(SIMDTarget.target.names == [SIMDTarget.targetName])
    }

    @Test("Names a set's targets best first")
    func namesTargetsBestFirst() {
        let targets: SIMDTargetSet = [.emu128, .sse4, .avx2]
        #expect(targets.names == ["AVX2", "SSE4", "EMU128"])
    }

    @Test("Supports EMU128 and SCALAR on every CPU")
    func supportsEmulatedTargets() {
        let supported = SIMDTarget.supportedTargets
        #expect(supported.contains(.emu128))
        #expect(supported.contains(.scalar))
    }

    @Test(
        "Runs on a CPU that supports the target it was compiled for",
        .disabled(
            if: SIMDTarget.target == .avx3ZEN4,
            "Highway reports AVX3_ZEN4 only on AMD CPUs, and CI runs that row under Intel's SDE"
        )
    )
    func supportsTarget() {
        #expect(SIMDTarget.isSupported)
    }

    @Test("Every element type fills the vector width of the target")
    func laneCountsFillTheVector() throws {
        let bytes = try #require(
            Self.vectorBytesOfTarget[SIMDTarget.targetName],
            "\(SIMDTarget.targetName) has no vector width in this test"
        )
        #expect(vectorBytes(of: SIMDUInt8.self) == bytes)
        #expect(vectorBytes(of: SIMDUInt16.self) == bytes)
        #expect(vectorBytes(of: SIMDUInt32.self) == bytes)
        #expect(vectorBytes(of: SIMDUInt64.self) == bytes)
        #expect(vectorBytes(of: SIMDInt8.self) == bytes)
        #expect(vectorBytes(of: SIMDInt16.self) == bytes)
        #expect(vectorBytes(of: SIMDInt32.self) == bytes)
        #expect(vectorBytes(of: SIMDInt64.self) == bytes)
        #expect(vectorBytes(of: SIMDFloat.self) == bytes)
        #expect(vectorBytes(of: SIMDDouble.self) == bytes)
    }

    @Test(
        "Compiles for the target the environment expects",
        .enabled(if: expectedTarget() != nil, "SIMD_EXPECTED_TARGET is not set")
    )
    func matchesExpectedTarget() throws {
        let expected = try #require(expectedTarget())
        #expect(SIMDTarget.targetName == expected)
    }
}
