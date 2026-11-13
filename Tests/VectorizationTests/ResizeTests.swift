import Testing
import Vectorization

@Suite("Resizing vectors and blocks")
struct ResizeTests {
    typealias H = SIMDUInt8
    typealias W = SIMDUInt32

    var lanes: Int { H.laneCount }
    var source: ContiguousArray<UInt8> { ContiguousArray((0..<lanes).map { UInt8($0) + 1 }) }

    func bytes(of vector: H.Vector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    func bytes(of vector: W.Vector) -> [UInt8] {
        var output = ContiguousArray<UInt32>(repeating: 0xFFFF_FFFF, count: W.laneCount)
        var destination = output.mutableSpan
        W.store(vector, to: &destination)
        return output.withUnsafeBytes { unsafe Array($0) }
    }

    func bytes(of vector: W.HalfVector) -> [UInt8] {
        var output = ContiguousArray<UInt32>(repeating: 0xFFFF_FFFF, count: W.laneCount / 2)
        var destination = output.mutableSpan
        W.store(vector, to: &destination)
        return output.withUnsafeBytes { unsafe Array($0) }
    }

    func bytes(of vector: H.HalfVector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes / 2)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    func bytes(of vector: H.QuarterVector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes / 4)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    func bytes(of vector: H.EighthVector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: lanes / 8)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    func bytes(of vector: H.BlockVector) -> [UInt8] {
        var output = ContiguousArray<UInt8>(repeating: 0xFF, count: 16)
        var destination = output.mutableSpan
        H.store(vector, to: &destination)
        return Array(output)
    }

    func poisoningUpperBytes(of vector: H.QuarterVector) -> H.QuarterVector {
        var poisoned = vector
        withUnsafeMutableBytes(of: &poisoned.raw) { raw in
            for index in lanes / 4..<raw.count {
                unsafe raw[index] = 0xA5
            }
        }
        return poisoned
    }

    func poisoningUpperBytes(of vector: H.EighthVector) -> H.EighthVector {
        var poisoned = vector
        withUnsafeMutableBytes(of: &poisoned.raw) { raw in
            for index in lanes / 8..<raw.count {
                unsafe raw[index] = 0xA5
            }
        }
        return poisoned
    }

    @Test("Resizing keeps the bytes both shapes have")
    func resizesKeepingBytes() {
        let source = source
        let vector = H.load(from: source.span)

        #expect(bytes(of: W.halfVector(resizing: vector)) == Array(source.prefix(lanes / 2)))
        #expect(
            bytes(of: H.quarterVector(resizing: H.loadHalf(from: source.span)))
                == Array(source.prefix(lanes / 4))
        )
        #expect(
            bytes(of: W.vector(resizing: H.loadQuarter(from: source.span))).prefix(lanes / 4)
                == source.prefix(lanes / 4)
        )
        #expect(
            bytes(of: W.halfVector(resizing: H.loadEighth(from: source.span))).prefix(lanes / 8)
                == source.prefix(lanes / 8)
        )
    }

    @Test(
        "Zero extending resizing zeroes the bytes past the source, whatever the unused lanes hold"
    )
    func zeroExtendsResizing() {
        let source = source
        let quarter = poisoningUpperBytes(of: H.loadQuarter(from: source.span))
        let eighth = poisoningUpperBytes(of: H.loadEighth(from: source.span))

        #expect(
            bytes(of: W.vector(zeroExtendingResizing: quarter))
                == Array(source.prefix(lanes / 4)) + Array(repeating: 0, count: lanes - lanes / 4)
        )
        #expect(
            bytes(of: H.halfVector(zeroExtendingResizing: eighth))
                == Array(source.prefix(lanes / 8))
                + Array(repeating: 0, count: lanes / 2 - lanes / 8)
        )
        #expect(
            bytes(of: H.vector(zeroExtendingResizing: eighth))
                == Array(source.prefix(lanes / 8)) + Array(repeating: 0, count: lanes - lanes / 8)
        )
        #expect(
            bytes(of: H.eighthVector(zeroExtendingResizing: H.load(from: source.span)))
                == Array(source.prefix(lanes / 8))
        )
    }

    @Test("A block is read from, and written to, the lanes of its index")
    func getsAndSetsBlocks() {
        let source = source
        let vector = H.load(from: source.span)
        let replacementLanes = ContiguousArray<UInt8>(repeating: 0xEE, count: 16)
        let replacement = H.loadBlock(from: replacementLanes.span)

        for index in 0..<H.blockCount {
            let range = index * 16..<(index + 1) * 16
            #expect(bytes(of: H.block(vector, at: index)) == Array(source[range]))
            #expect(bytes(of: unsafe H.block(vector, atUnchecked: index)) == Array(source[range]))

            var expected = Array(source)
            expected.replaceSubrange(range, with: Array(repeating: 0xEE, count: 16))
            #expect(bytes(of: H.replacingBlock(vector, at: index, with: replacement)) == expected)
        }
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked block ops trap on an index outside the vector")
    func checkedBlockOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.block(SIMDUInt8.zero(), at: SIMDUInt8.blockCount)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.block(SIMDUInt8.zero(), at: -1)
        }
        await #expect(processExitsWith: .failure) {
            let block = SIMDUInt8.block(SIMDUInt8.zero(), at: 0)
            _ = SIMDUInt8.replacingBlock(SIMDUInt8.zero(), at: SIMDUInt8.blockCount, with: block)
        }
    }
    #endif
}
