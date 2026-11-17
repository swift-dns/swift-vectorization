import Testing
import Vectorization

@Suite("Type checking")
struct TypeCheckingTests {
    @Test("A lane count in a comparison with a mapped range type-checks")
    func propertyInComparison() {
        typealias H = SIMD<UInt8>
        var output = ContiguousArray<UInt8>(repeating: 0, count: H.laneCount)
        var destination = output.mutableSpan
        H.store(
            H.adding(H.bitwiseAnd(H.iota(0), H.repeating(15)), H.repeating(0x10)),
            to: &destination
        )

        #expect(Array(output) == (0..<H.laneCount).map { UInt8(0x10 + $0 % 16) })
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("A lane count in the arithmetic of an exit test closure type-checks")
    func propertyArithmeticInClosure() async {
        await #expect(processExitsWith: .failure) {
            let count = (SIMD<UInt8>.laneCount + 7) / 8 - 1
            let input = ContiguousArray<UInt8>(repeating: 0, count: count)
            _ = SIMD<UInt8>.loadMask(from: input.span)
        }
    }
    #endif

    @Test("Op calls in a comparison type-check")
    func opCallsInComparison() {
        typealias H = SIMD<UInt8>
        let a = H.iota(1)

        #expect(
            H.trueCount(H.equalTo(H.bitwiseAnd(a, H.repeating(3)), H.repeating(3)))
                == (0..<H.laneCount).filter { $0 % 4 == 2 }.count
        )
        #expect(
            H.sum(H.adding(a, H.repeating(1)))
                == UInt8(truncatingIfNeeded: 2 * H.laneCount + H.laneCount * (H.laneCount - 1) / 2)
        )
        #expect(
            (0..<H.laneCount).map { H.lane(H.shiftedLeft(a, by: 3), at: $0) }
                == (0..<H.laneCount).map { UInt8(truncatingIfNeeded: ($0 + 1) << 3) }
        )
    }

    @Test("Nested op calls with literals in a comparison type-check")
    func nestedOpsInComparison() {
        typealias I = SIMD<Int32>
        let a = I.iota(0)

        #expect(
            I.sum(
                I.adding(
                    I.multiplying(a, I.repeating(1 + 2 * 3)),
                    I.subtracting(I.repeating(4), I.repeating(5))
                )
            ) == Int32((0..<I.laneCount).map { $0 * 7 - 1 }.reduce(0, +))
        )
    }

    @Test("The lane counts of two lane types type-check in arithmetic with literals")
    func laneCountsOfTwoLaneTypes() {
        #expect(SIMD<UInt8>.laneCount == 4 * SIMD<Int32>.laneCount)
        #expect(SIMD<UInt8>.laneCount - 2 * SIMD<UInt16>.laneCount == 0)
        #expect(SIMD<Int32>.laneCount * 2 + 1 == SIMD<Double>.laneCount * 4 + 1)
        #expect(
            (SIMD<Float>.laneCount + 3) / 4 - 1 + 2 * SIMD<Int64>.laneCount
                == (SIMD<Int32>.laneCount + 3) / 4 - 1 + SIMD<Int32>.laneCount
        )
    }

    @Test(
        "The block counts and lane counts of two lane types type-check in arithmetic with literals"
    )
    func blockCountsOfTwoLaneTypes() {
        #expect(SIMD<UInt8>.blockCount == SIMD<Double>.blockCount)
        #expect(SIMD<UInt8>.blockCount * 16 / SIMD<Float>.laneCount == 4)
        #expect(SIMD<Int64>.laneCount * 8 == SIMD<Int8>.blockCount * 16)
        #expect(
            Array(0..<SIMD<UInt8>.blockCount).map { $0 * 16 }.last == SIMD<UInt8>.laneCount - 16
        )
    }

    @Test("Op calls of two lane types type-check in arithmetic with their lane counts")
    func opCallsOfTwoLaneTypes() {
        typealias H = SIMD<UInt8>
        typealias D = SIMD<Double>

        #expect(
            H.trueCount(H.lessThan(H.iota(0), H.repeating(3)))
                + D.trueCount(D.lessThan(D.iota(0), D.repeating(2)))
                == min(3, H.laneCount) + min(2, D.laneCount)
        )
    }
}
