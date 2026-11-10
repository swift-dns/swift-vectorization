import Testing
import Vectorization

@Suite("Narrow vectors")
struct NarrowVectorTests {
    typealias H = SIMDUInt8

    var lanes: Int { H.laneCount }

    func stored(_ vector: H.Vector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    func stored(_ vector: H.HalfVector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes / 2)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    @Test("A narrow vector loads and stores exactly its own lanes")
    func loadsAndStores() {
        let source = ContiguousArray((0..<lanes).map { UInt8($0) + 1 })
        let half = H.loadHalf(from: source.span)
        let quarter = H.loadQuarter(from: source.span)
        let eighth = H.loadEighth(from: source.span)
        let block = H.loadBlock(from: source.span)

        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes)
        var destination = output.mutableSpan
        H.store(half, to: &destination)
        #expect(Array(output.prefix(lanes / 2)) == Array(source.prefix(lanes / 2)))
        #expect(output.dropFirst(lanes / 2).allSatisfy { $0 == 0xFF })

        output = ContiguousArray(repeating: 0xFF, count: lanes)
        destination = output.mutableSpan
        H.store(quarter, to: &destination)
        #expect(Array(output.prefix(lanes / 4)) == Array(source.prefix(lanes / 4)))
        #expect(output.dropFirst(lanes / 4).allSatisfy { $0 == 0xFF })

        output = ContiguousArray(repeating: 0xFF, count: lanes)
        destination = output.mutableSpan
        H.store(eighth, to: &destination)
        #expect(Array(output.prefix(lanes / 8)) == Array(source.prefix(lanes / 8)))
        #expect(output.dropFirst(lanes / 8).allSatisfy { $0 == 0xFF })

        output = ContiguousArray(repeating: 0xFF, count: lanes)
        destination = output.mutableSpan
        H.store(block, to: &destination)
        #expect(Array(output.prefix(16)) == Array(source.prefix(16)))
        #expect(output.dropFirst(16).allSatisfy { $0 == 0xFF })
    }

    @Test("A half vector converts to and from its SIMD type")
    func convertsToSIMD() {
        let source = ContiguousArray((0..<lanes).map { UInt8($0) + 1 })
        let half = H.loadHalf(from: source.span)
        let simd = half.simd

        #expect((0..<simd.scalarCount).map { simd[$0] } == Array(source.prefix(lanes / 2)))
        #expect(stored(H.HalfVector(simd)) == Array(source.prefix(lanes / 2)))
    }

    @Test("Halves split a vector and combine into it")
    func splitsAndCombines() {
        let source = ContiguousArray((0..<lanes).map { UInt8($0) + 1 })
        let vector = H.load(from: source.span)
        let lower = H.lowerHalf(vector)
        let upper = H.upperHalf(vector)

        #expect(stored(lower) == Array(source.prefix(lanes / 2)))
        #expect(stored(upper) == Array(source.suffix(lanes / 2)))
        #expect(stored(H.combining(upper, lower)) == Array(source))
        #expect(
            stored(H.combining(lower, upper))
                == Array(source.suffix(lanes / 2) + source.prefix(lanes / 2))
        )
    }

    @Test("Zero extending a half vector zeroes the upper half")
    func zeroExtends() {
        let source = ContiguousArray((0..<lanes).map { UInt8($0) + 1 })
        let lower = H.lowerHalf(H.load(from: source.span))

        #expect(
            stored(H.zeroExtending(lower))
                == Array(source.prefix(lanes / 2)) + Array(repeating: 0, count: lanes / 2)
        )
    }

    @Test("A half vector of 64-bit lanes splits and combines, however many lanes it has")
    func splitsAndCombinesWideLanes() {
        let source = ContiguousArray((0..<SIMDUInt64.laneCount).map { UInt64($0) + 1 })
        let vector = SIMDUInt64.load(from: source.span)
        let lower = SIMDUInt64.lowerHalf(vector)
        let upper = SIMDUInt64.upperHalf(vector)
        let half = SIMDUInt64.laneCount / 2

        var output = ContiguousArray<UInt64>(repeating: 0, count: half)
        var destination = output.mutableSpan
        SIMDUInt64.store(upper, to: &destination)
        #expect(Array(output) == Array(source.suffix(half)))

        output = ContiguousArray(repeating: 0, count: half)
        destination = output.mutableSpan
        SIMDUInt64.store(SIMDUInt64.HalfVector(lower.simd), to: &destination)
        #expect(Array(output) == Array(source.prefix(half)))
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked loads and stores of narrow vectors trap on a span that is too short")
    func checkedSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount / 2 - 1)
            _ = SIMDUInt8.loadHalf(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount / 4 - 1)
            _ = SIMDUInt8.loadQuarter(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount / 8 - 1)
            _ = SIMDUInt8.loadEighth(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: 15)
            _ = SIMDUInt8.loadBlock(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            let half = SIMDUInt8.lowerHalf(SIMDUInt8.zero())
            var output = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount / 2 - 1)
            var destination = output.mutableSpan
            SIMDUInt8.store(half, to: &destination)
        }
    }
    #endif
}
