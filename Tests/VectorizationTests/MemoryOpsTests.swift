import Testing
import Vectorization

@Suite("Memory ops")
struct MemoryOpsTests {
    typealias H = SIMDInt32

    var lanes: Int { H.laneCount }

    func stored(_ vector: H.Vector) -> [Int32] {
        var output = ContiguousArray<Int32>(repeating: -1, count: lanes)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    @Test("A masked load takes the lanes of the mask from memory and the others from otherwise")
    func maskedLoad() {
        let source = ContiguousArray((0..<lanes).map { Int32($0) + 1 })
        let mask = H.firstLanes(count: lanes - 1)
        let zeroed = stored(H.load(from: source.span, where: mask))
        let merged = stored(H.load(from: source.span, where: mask, otherwise: H.repeating(-5)))

        #expect(zeroed == (0..<lanes).map { $0 < lanes - 1 ? Int32($0) + 1 : 0 })
        #expect(merged == (0..<lanes).map { $0 < lanes - 1 ? Int32($0) + 1 : -5 })
    }

    @Test("A blended store only writes the lanes of the mask")
    func blendedStore() {
        var output = ContiguousArray<Int32>(repeating: 7, count: lanes)
        var destination = output.mutableSpan
        H.store(H.iota(1), to: &destination, where: H.firstLanes(count: 2))

        #expect(Array(output) == (0..<lanes).map { $0 < 2 ? Int32($0) + 1 : 7 })
    }

    @Test("A gather and a scatter go through the indices")
    func gatherAndScatter() {
        let source = ContiguousArray((0..<lanes).map { Int32($0) * 10 })
        let reversed = H.subtracting(H.repeating(Int32(lanes - 1)), H.iota(0))
        let gathered = H.gather(from: source.span, indices: reversed)

        #expect(stored(gathered) == source.reversed())

        var output = ContiguousArray<Int32>(repeating: -1, count: lanes)
        var destination = output.mutableSpan
        H.scatter(gathered, to: &destination, indices: reversed)

        #expect(output == source)
    }

    @Test("A masked gather leaves out the lanes of a mask that select nothing in the span")
    func maskedGather() {
        let source = ContiguousArray<Int32>(repeating: 3, count: lanes)
        let indices = H.iota(0)
        let outOfRange = H.adding(indices, H.repeating(Int32(lanes)))
        let mask = H.firstLanes(count: 0)
        let gathered = H.gather(
            from: source.span,
            indices: outOfRange,
            where: mask,
            otherwise: H.repeating(9)
        )

        #expect(stored(gathered) == [Int32](repeating: 9, count: lanes))
    }

    @Test("A compress store writes the lanes of the mask, from the start")
    func compressStore() {
        let mask = H.firstLanes(count: lanes - 1)
        var output = ContiguousArray<Int32>(repeating: -1, count: lanes)
        var destination = output.mutableSpan
        let count = H.storeCompressedBlended(H.iota(1), where: mask, to: &destination)

        #expect(count == lanes - 1)
        #expect(Array(output) == (0..<lanes).map { $0 < lanes - 1 ? Int32($0) + 1 : -1 })
    }

    @Test("A safe fill and a safe copy stop at the end of the shortest span")
    func safeFillAndCopy() {
        var filled = ContiguousArray<Int32>(repeating: 0, count: 2)
        var destination = filled.mutableSpan
        H.storeRepeating(4, to: &destination)

        #expect(Array(filled) == [4, 4])

        let source = ContiguousArray((0..<lanes).map { Int32($0) + 1 })
        var copied = ContiguousArray<Int32>(repeating: 0, count: 2)
        var copy = copied.mutableSpan
        H.copy(from: source.span, to: &copy)

        #expect(Array(copied) == [1, 2])
    }

    @Test("A truncating store keeps the low bits of the lanes")
    func truncatingStore() {
        var output = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt32.laneCount)
        var destination = output.mutableSpan
        SIMDUInt32.storeTruncating(SIMDUInt32.repeating(0x1234_56AB), to: &destination)

        #expect(Array(output) == [UInt8](repeating: 0xAB, count: SIMDUInt32.laneCount))
    }

    @Test("Indices loaded from memory select lanes")
    func loadedIndices() {
        let reversed = ContiguousArray((0..<lanes).map { Int32(lanes - 1 - $0) })
        let source = ContiguousArray((0..<lanes).map { Int32($0) + 100 })
        let loaded = H.loadIndices(from: reversed.span)
        let permuted = H.tableLookupLanes(H.load(from: source.span), at: loaded)

        #expect(stored(permuted) == source.reversed())
    }
}
