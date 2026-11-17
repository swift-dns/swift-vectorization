import Testing
import Vectorization

func maskHighNibbles(
    _ input: UnsafePointer<UInt8>,
    _ count: Int,
    _ output: UnsafeMutablePointer<UInt8>
) {
    typealias H = SIMD<UInt8>

    let lanes = H.laneCount
    let mask = H.repeating(0x0F)
    var index = 0

    while count - index >= lanes {
        let loaded = unsafe H.load(from: input + index)
        unsafe H.store(H.bitwiseAnd(H.shiftedRight(loaded, by: 2), mask), to: output + index)
        index += lanes
    }
}

func sum<Lane: SIMDIntegerElement>(
    _ input: UnsafePointer<Lane>,
    _ count: Int
) -> SIMD<Lane> {
    var total = SIMD<Lane>.zero()
    var index = 0
    while count - index >= SIMD<Lane>.laneCount {
        total = unsafe SIMD<Lane>.adding(total, SIMD<Lane>.load(from: input + index))
        index += SIMD<Lane>.laneCount
    }
    return total
}

func sum<Lane: SIMDIntegerElement>(_ input: Span<Lane>) -> SIMD<Lane> {
    var total = SIMD<Lane>.zero()
    var rest = input
    while rest.count >= SIMD<Lane>.laneCount {
        total = SIMD<Lane>.adding(total, SIMD<Lane>.load(from: rest))
        rest = rest.extracting(droppingFirst: SIMD<Lane>.laneCount)
    }
    return SIMD<Lane>.adding(total, SIMD<Lane>.loadFirst(from: rest))
}

@Suite("Kernels")
struct KernelTests {
    @Test("A hand-written kernel masks high nibbles")
    func kernelExample() {
        let lanes = SIMD<UInt8>.laneCount
        let input = (0..<(lanes * 2)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var output = [UInt8](repeating: 0, count: lanes * 2)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                unsafe maskHighNibbles(source.baseAddress!, input.count, destination.baseAddress!)
            }
        }

        #expect(output == input.map { ($0 >> 2) & 0x0F })
    }

    @Test("A generic kernel sums lanes")
    func genericExample() {
        let lanes = SIMD<Int32>.laneCount
        let input = (0..<(lanes * 3)).map { Int32($0) }

        let total = input.withUnsafeBufferPointer { source in
            unsafe SIMD<Int32>.sum(sum(source.baseAddress!, input.count))
        }

        #expect(total == input.reduce(0, &+))
    }

    @Test("A generic span kernel sums lanes, including a partial last vector")
    func genericSpanExample() {
        let lanes = SIMD<Int32>.laneCount
        let input = ContiguousArray((0..<(lanes * 3 + 1)).map { Int32($0) })

        let total = SIMD<Int32>.sum(sum(input.span))

        #expect(total == input.reduce(0, &+))
    }
}
