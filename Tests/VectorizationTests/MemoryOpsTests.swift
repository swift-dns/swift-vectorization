import CVectorizationOps
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

    @Test("A gather and a scatter reach the last lane of the span by index and by byte offset")
    func gatherAndScatterReachLastLane() {
        let source = ContiguousArray((0..<lanes).map { Int32($0) * 10 })
        let last = Int32(lanes - 1)
        let byIndex = H.gather(from: source.span, indices: H.repeating(last))
        let byOffset = H.gather(from: source.span, byteOffsets: H.repeating(last * 4))

        #expect(stored(byIndex) == [Int32](repeating: last * 10, count: lanes))
        #expect(stored(byOffset) == [Int32](repeating: last * 10, count: lanes))

        var output = ContiguousArray<Int32>(repeating: -1, count: lanes)
        var destination = output.mutableSpan
        H.scatter(H.repeating(5), to: &destination, indices: H.repeating(last))

        #expect(Array(output) == (0..<lanes).map { $0 == lanes - 1 ? 5 : -1 })
    }

    @Test("The index limit of a gather counts the indices or byte offsets that select a lane")
    func gatherIndexLimit() {
        let limits32 = [
            (0, 1), (4, 1), (Int.max, 1), (0, 4), (1, 4), (4, 4), (1 << 29, 4), ((1 << 29) + 1, 4),
            (Int.max, 4),
        ].map { UInt64(UInt(bitPattern: SIMDInt32.indexLimit(count: $0.0, stride: $0.1))) }
        let limits64 = [(0, 1), (4, 1), (Int.max, 1), (4, 8), ((1 << 28) + 1, 8), (1 << 29, 8)]
            .map { UInt64(UInt(bitPattern: SIMDInt64.indexLimit(count: $0.0, stride: $0.1))) }

        let expected32: [UInt64] = [
            0, 4, Swift.min(UInt64(Int.max), 1 << 31), 0, 1, 13, (1 << 31) - 3, 1 << 31, 1 << 31,
        ]
        let expected64: [UInt64] = [0, 4, UInt64(Int.max), 25, (1 << 31) + 1, (1 << 32) - 7]

        #expect(limits32 == expected32)
        #expect(limits64 == expected64)
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

    @Test(
        "The index checks of masked gathers and scatters reject an index outside the span in a used lane"
    )
    func maskedIndexChecksOfNonCanonicalMasks() {
        typealias U = SIMDUInt32
        typealias D = SIMDDouble
        let scattersBySignBit = SIMDTarget.targetName.hasPrefix("AVX3")
        let gathersBySignBit = scattersBySignBit || SIMDTarget.targetName == "AVX2"
        let indices32 = SIMDInt32.load(
            from: ContiguousArray((0..<U.laneCount).map { $0 == U.laneCount - 1 ? 64 : 0 }).span
        )
        let indices64 = SIMDInt64.load(
            from: ContiguousArray((0..<D.laneCount).map { $0 == D.laneCount - 1 ? 64 : 0 }).span
        )

        for bits: UInt64 in [0, 1, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0000_0000_0000, ~0] {
            let low = UInt32(truncatingIfNeeded: bits)
            let lanes32 = ContiguousArray((0..<U.laneCount).map { $0 < U.laneCount - 1 ? ~0 : low })
            let lanes64 = ContiguousArray(
                (0..<D.laneCount).map { Double(bitPattern: $0 == D.laneCount - 1 ? bits : ~0) }
            )
            let mask32 = U.mask(from: U.load(from: lanes32.span))
            let mask64 = D.mask(from: D.load(from: lanes64.span))
            let lane32 = U.lane(U.vector(from: mask32), at: U.laneCount - 1)
            let lane64 = D.lane(D.vector(from: mask64), at: D.laneCount - 1).bitPattern
            let isUsed32 = { (bySignBit: Bool) in bySignBit ? lane32 >> 31 != 0 : lane32 != 0 }
            let isUsed64 = { (bySignBit: Bool) in bySignBit ? lane64 >> 63 != 0 : lane64 != 0 }

            #expect(
                cvectorization_ops_gather_indices_within_where_u32(indices32.raw, 65, mask32.raw)
            )
            #expect(cvectorization_ops_indices_within_where_u32(indices32.raw, 65, mask32.raw))
            #expect(
                cvectorization_ops_gather_indices_within_where_f64(indices64.raw, 65, mask64.raw)
            )
            #expect(cvectorization_ops_indices_within_where_f64(indices64.raw, 65, mask64.raw))
            #expect(
                cvectorization_ops_gather_indices_within_where_u32(indices32.raw, 64, mask32.raw)
                    == !isUsed32(gathersBySignBit)
            )
            #expect(
                cvectorization_ops_indices_within_where_u32(indices32.raw, 64, mask32.raw)
                    == !isUsed32(scattersBySignBit)
            )
            #expect(
                cvectorization_ops_gather_indices_within_where_f64(indices64.raw, 64, mask64.raw)
                    == !isUsed64(gathersBySignBit)
            )
            #expect(
                cvectorization_ops_indices_within_where_f64(indices64.raw, 64, mask64.raw)
                    == !isUsed64(scattersBySignBit)
            )
        }
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
