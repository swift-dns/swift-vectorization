import Testing
import Vectorization

func laneValues<Lane: SIMDPrototypeLane>(of vector: SIMD<Lane>) -> [Lane] {
    (0..<SIMD<Lane>.laneCount).map { SIMD<Lane>.lane(vector, at: $0) }
}

func sumOfDoubled<Lane: SIMDPrototypeLane>(_ vector: SIMD<Lane>) -> Lane {
    SIMD<Lane>.sum(SIMD<Lane>.adding(vector, vector))
}

@Suite("Prototype")
struct PrototypeTests {
    @Test("A generic vector of UInt8 repeats, loads, compares and counts as the namespace does")
    func concreteUInt8() {
        typealias V = SIMD<UInt8>
        let count = V.laneCount
        let input = (0..<count).map { UInt8(truncatingIfNeeded: $0 % 4) }

        let loaded = input.withUnsafeBufferPointer { unsafe V.load(from: $0.baseAddress!) }
        let mask = V.equalTo(loaded, V.repeating(2))
        let expected = SIMDUInt8.trueCount(
            SIMDUInt8.equalTo(loaded.storage, SIMDUInt8.repeating(2))
        )

        #expect(count == SIMDUInt8.laneCount)
        #expect(laneValues(of: loaded) == input)
        #expect(V.trueCount(mask) == input.filter { $0 == 2 }.count)
        #expect(V.trueCount(mask) == expected)
    }

    @Test("A generic vector survives a span store after a span load")
    func spanRoundTrip() {
        typealias V = SIMD<Int32>
        let count = V.laneCount
        let source = ContiguousArray((0..<count).map { Int32($0) * 3 - 5 })
        var output = ContiguousArray<Int32>(repeating: -1, count: count)

        var destination = output.mutableSpan
        V.store(V.load(from: source.span), to: &destination)

        #expect(Array(output) == Array(source))
    }

    @Test("An integer-only op shifts the lanes of a generic vector")
    func integerOnlyOp() {
        typealias V = SIMD<UInt32>
        let shifted = V.shiftedLeft(V.iota(1), by: 3)

        #expect(laneValues(of: shifted) == (0..<V.laneCount).map { UInt32($0 + 1) << 3 })
    }

    @Test("A float-only op takes the square root of the lanes of a generic vector")
    func floatOnlyOp() {
        typealias V = SIMD<Float>
        let count = V.laneCount
        let squares = (0..<count).map { Float($0 * $0) }

        let roots = squares.withUnsafeBufferPointer {
            V.squareRoot(unsafe V.load(from: $0.baseAddress!))
        }

        #expect(laneValues(of: roots) == (0..<count).map { Float($0) })
    }

    @Test("A generic function infers the lane type from the vector it is given")
    func genericFunction() {
        let count = SIMD<Int32>.laneCount

        #expect(sumOfDoubled(SIMD<Int32>.iota(0)) == Int32(count * (count - 1)))
        #expect(sumOfDoubled(SIMD<Float>.repeating(1.5)) == Float(count) * 3)
    }
}
