import Testing
import Vectorization

private let integerPattern = [
    0, 1, -1, 100, 127, 128, 200, 255, 256, -128, -129, 1000, -1000, 32767, 65535, 70000, 100000,
    -100000, 40000, 65536, -32768,
]
private let smallPattern = [0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89]
private let floatPattern: [Double] = [
    0, 0.5, 1.5, 2.5, -0.5, -1.5, -2.5, 3.25, -7.75, 100.5, -100.5, 1000.25, 0.1, -0.1, 12345.5,
    3.5, -3.5,
]

private func integerVector<Lane: SIMDPrototypeLane & FixedWidthInteger>(
    _ pattern: [Int],
    seed: Int = 0
) -> SIMD<Lane> {
    let values = ContiguousArray(
        (0..<SIMD<Lane>.laneCount).map {
            Lane(truncatingIfNeeded: pattern[($0 * 5 + seed) % pattern.count])
        }
    )
    return SIMD<Lane>.load(from: values.span)
}

private func floatVector<Lane: SIMDPrototypeLane & BinaryFloatingPoint>(
    seed: Int = 0
) -> SIMD<Lane> {
    let values = ContiguousArray(
        (0..<SIMD<Lane>.laneCount).map { Lane(floatPattern[($0 * 5 + seed) % floatPattern.count]) }
    )
    return SIMD<Lane>.load(from: values.span)
}

private func someMask<Lane: SIMDPrototypeLane & Comparable>(_ a: SIMD<Lane>) -> SIMD<Lane>.Mask {
    let median = laneValues(of: a).sorted()[SIMD<Lane>.laneCount / 2]
    return SIMD<Lane>.lessThan(a, SIMD<Lane>.repeating(median))
}

private func gatherIndices() -> SIMD<Int32> {
    let values = ContiguousArray((0..<SIMD<Int32>.laneCount).map { Int32(($0 * 7 + 3) % 64) })
    return SIMD<Int32>.load(from: values.span)
}

private struct LaneVectors {
    let uint8: SIMD<UInt8>
    let int8: SIMD<Int8>
    let uint16: SIMD<UInt16>
    let int16: SIMD<Int16>
    let uint32: SIMD<UInt32>
    let int32: SIMD<Int32>
    let float: SIMD<Float>
    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    let float16: SIMD<Float16>
    #endif

    init(_ pattern: [Int]) {
        uint8 = integerVector(pattern)
        int8 = integerVector(pattern, seed: 1)
        uint16 = integerVector(pattern, seed: 2)
        int16 = integerVector(pattern, seed: 3)
        uint32 = integerVector(pattern, seed: 4)
        int32 = integerVector(pattern, seed: 5)
        float = floatVector()
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        float16 = floatVector(seed: 1)
        #endif
    }
}

private func lanes<E: SIMDElement>(_ type: E.Type, _ vector: E.Vector) -> [E.Lane] {
    let output = ContiguousArray<E.Lane>(capacity: E.laneCount) { output in
        E.append(vector, to: &output)
    }
    return Array(output)
}

private func halfLanes(_ half: SIMDUInt8.HalfVector) -> [UInt8] {
    Array(ContiguousArray<UInt8>(capacity: SIMDUInt8.laneCount) { SIMDUInt8.append(half, to: &$0) })
}

private func halfLanes(_ half: SIMDInt8.HalfVector) -> [Int8] {
    Array(ContiguousArray<Int8>(capacity: SIMDInt8.laneCount) { SIMDInt8.append(half, to: &$0) })
}

private func halfLanes(_ half: SIMDUInt16.HalfVector) -> [UInt16] {
    Array(
        ContiguousArray<UInt16>(capacity: SIMDUInt16.laneCount) { SIMDUInt16.append(half, to: &$0) }
    )
}

private func halfLanes(_ half: SIMDInt16.HalfVector) -> [Int16] {
    Array(ContiguousArray<Int16>(capacity: SIMDInt16.laneCount) { SIMDInt16.append(half, to: &$0) })
}

private func halfLanes(_ half: SIMDUInt32.HalfVector) -> [UInt32] {
    Array(
        ContiguousArray<UInt32>(capacity: SIMDUInt32.laneCount) { SIMDUInt32.append(half, to: &$0) }
    )
}

private func halfLanes(_ half: SIMDInt32.HalfVector) -> [Int32] {
    Array(ContiguousArray<Int32>(capacity: SIMDInt32.laneCount) { SIMDInt32.append(half, to: &$0) })
}

private func halfLanes(_ half: SIMDFloat.HalfVector) -> [Float] {
    Array(ContiguousArray<Float>(capacity: SIMDFloat.laneCount) { SIMDFloat.append(half, to: &$0) })
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
private func halfLanes(_ half: SIMDFloat16.HalfVector) -> [Float16] {
    Array(
        ContiguousArray<Float16>(capacity: SIMDFloat16.laneCount) {
            SIMDFloat16.append(half, to: &$0)
        }
    )
}
#endif

private func expectEqual<E: SIMDElement>(
    _ actual: SIMD<E.Lane>,
    _ expected: E.Vector,
    in namespace: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation
) where E.Lane: SIMDPrototypeLane & Equatable {
    #expect(laneValues(of: actual) == lanes(namespace, expected), sourceLocation: sourceLocation)
}

private func expectEqual<E: SIMDElement>(
    _ actual: SIMD<E.Lane>.Mask,
    _ expected: E.Mask,
    in namespace: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation
) where E.Lane: SIMDPrototypeLane {
    #expect(
        SIMD<E.Lane>.bits(of: actual) == namespace.bits(of: expected),
        sourceLocation: sourceLocation
    )
}

private func halves<Lane: SIMDPrototypeLinkedLane>(
    of a: SIMD<Lane>
) -> (lower: SIMD<Lane>.HalfVector, upper: SIMD<Lane>.HalfVector, combined: SIMD<Lane>) {
    let lower = SIMD<Lane>.lowerHalf(a)
    let upper = SIMD<Lane>.upperHalf(a)
    return (lower, upper, SIMD<Lane>.combining(upper, lower))
}

private func reinterpreted<Source: SIMDPrototypeLinkedLane, Result: SIMDPrototypeLinkedLane>(
    _ a: SIMD<Source>,
    as result: Result.Type
) -> SIMD<Result> {
    SIMD<Result>.vector(bitPattern: a)
}

private func rebound<Source: SIMDPrototypeLinkedLane, Lane: SIMDPrototypeLinkedLane>(
    _ a: SIMD<Source>.Mask,
    to lane: Lane.Type
) -> SIMD<Lane>.Mask where Source.Unsigned == Lane.Unsigned {
    SIMD<Lane>.mask(rebinding: a)
}

private func unsignedMask<Lane: SIMDPrototypeLinkedLane>(
    of a: SIMD<Lane>.Mask
) -> SIMD<Lane.Unsigned>.Mask {
    SIMD<Lane.Unsigned>.mask(rebinding: a)
}

private func widened<Source: SIMDPrototypeWidenableLane>(
    _ a: SIMD<Source>.HalfVector
) -> SIMD<Source.Wide> {
    SIMD<Source.Wide>.vector(widening: a)
}

private func widened<Lane: SIMDPrototypeNarrowableLane>(
    _ a: SIMD<Lane.Narrow>.HalfVector,
    to lane: Lane.Type
) -> SIMD<Lane> {
    SIMD<Lane>.vector(widening: a)
}

private func multipliedEven<Lane: SIMDPrototypeWideIntegerLane>(
    _ a: SIMD<Lane.Narrow>,
    _ b: SIMD<Lane.Narrow>,
    as lane: Lane.Type
) -> SIMD<Lane> {
    SIMD<Lane>.multiplyingEven(a, b)
}

private func multipliedEven<Narrow: SIMDPrototypeWidenableLane>(
    _ a: SIMD<Narrow>,
    _ b: SIMD<Narrow>
) -> SIMD<Narrow.Wide> where Narrow.Wide: SIMDPrototypeWideIntegerLane {
    SIMD<Narrow.Wide>.multiplyingEven(a, b)
}

private func clampedToSigned<Source: SIMDPrototypeWideIntegerLane>(
    _ a: SIMD<Source>
) -> SIMD<Source.Narrow.Signed>.HalfVector {
    SIMD<Source.Narrow.Signed>.halfVector(clamping: a)
}

private func clampedToUnsigned<Source: SIMDPrototypeWideIntegerLane>(
    _ a: SIMD<Source>
) -> SIMD<Source.Narrow.Unsigned>.HalfVector {
    SIMD<Source.Narrow.Unsigned>.halfVector(clamping: a)
}

private func clamped<Source: SIMDPrototypeWideIntegerLane, Lane: SIMDPrototypeIntegerLane>(
    _ a: SIMD<Source>,
    to lane: Lane.Type
) -> SIMD<Lane>.HalfVector where Source.Narrow.Signed == Lane {
    SIMD<Lane>.halfVector(clamping: a)
}

private func clamped<Source: SIMDPrototypeWideIntegerLane, Lane: SIMDPrototypeIntegerLane>(
    _ a: SIMD<Source>,
    to lane: Lane.Type
) -> SIMD<Lane>.HalfVector where Source.Narrow.Unsigned == Lane {
    SIMD<Lane>.halfVector(clamping: a)
}

private func clampedFromWide<Lane: SIMDPrototypeWidenableLane & SIMDPrototypeIntegerLane>(
    _ a: SIMD<Lane.Wide>,
    to lane: Lane.Type
) -> SIMD<Lane>.HalfVector
where Lane.Wide: SIMDPrototypeWideIntegerLane, Lane.Signed == Lane {
    SIMD<Lane>.halfVector(clamping: a)
}

private func converted<Lane: SIMDPrototypeFloatLane, Source: SIMDPrototypeFloatConvertibleLane>(
    _ a: SIMD<Source>,
    to lane: Lane.Type
) -> SIMD<Lane> where Source.Float == Lane {
    SIMD<Lane>.vector(converting: a)
}

private func converted<Lane: SIMDPrototypeFloatConvertibleLane>(
    _ a: SIMD<Lane.Float>,
    to lane: Lane.Type
) -> SIMD<Lane> {
    SIMD<Lane>.vector(converting: a)
}

private func convertedToSigned<Lane: SIMDPrototypeFloatLane>(
    _ a: SIMD<Lane>
) -> SIMD<Lane.Signed> {
    SIMD<Lane.Signed>.vector(converting: a)
}

private func convertedFromSigned<Lane: SIMDPrototypeFloatLane>(
    _ a: SIMD<Lane.Signed>
) -> SIMD<Lane> {
    SIMD<Lane>.vector(converting: a)
}

private func rounded<Lane: SIMDPrototypeFloatLane>(_ a: SIMD<Lane>) -> SIMD<Lane.Signed> {
    SIMD<Lane.Signed>.vector(roundingToNearestOrEven: a)
}

private func rounded<Lane: SIMDPrototypeFloatConvertibleLane>(
    _ a: SIMD<Lane.Float>,
    to lane: Lane.Type
) -> SIMD<Lane> where Lane.Float.Signed == Lane {
    SIMD<Lane>.vector(roundingToNearestOrEven: a)
}

private func truncated<
    Source: SIMDPrototypeUnsignedIntegerLane & SIMDPrototypeWideIntegerLane
>(
    _ a: SIMD<Source>
) -> SIMD<Source.Narrow>.HalfVector where Source.Narrow: SIMDPrototypeUnsignedIntegerLane {
    SIMD<Source.Narrow>.halfVector(truncatingIfNeeded: a)
}

private func truncated<
    Source: SIMDPrototypeUnsignedIntegerLane & SIMDPrototypeWideIntegerLane,
    Lane: SIMDPrototypeUnsignedIntegerLane
>(
    _ a: SIMD<Source>,
    to lane: Lane.Type
) -> SIMD<Lane>.HalfVector where Source.Narrow == Lane {
    SIMD<Lane>.halfVector(truncatingIfNeeded: a)
}

private func narrowed<Source: SIMDPrototypeLinkedLane, Lane: SIMDPrototypeWidenableLane>(
    _ a: SIMD<Source>.Mask,
    _ b: SIMD<Source>.Mask,
    to lane: Lane.Type
) -> SIMD<Lane>.Mask where Source.Unsigned == Lane.Wide.Unsigned {
    SIMD<Lane>.mask(narrowing: a, b)
}

private func narrowedFromWide<Lane: SIMDPrototypeWidenableLane>(
    _ a: SIMD<Lane.Wide>.Mask,
    _ b: SIMD<Lane.Wide>.Mask,
    to lane: Lane.Type
) -> SIMD<Lane>.Mask {
    SIMD<Lane>.mask(narrowing: a, b)
}

private func gathered<Lane: SIMDPrototypeGatherableLane>(
    from span: Span<Lane>,
    indices: SIMD<Lane.Signed>
) -> SIMD<Lane> {
    SIMD<Lane>.gather(from: span, indices: indices)
}

private func gathered<Lane: SIMDPrototypeGatherableLane>(
    from pointer: UnsafePointer<Lane>,
    indices: SIMD<Lane.Signed>
) -> SIMD<Lane> {
    unsafe SIMD<Lane>.gather(from: pointer, indices: indices)
}

private func gatheredUnchecked<Lane: SIMDPrototypeGatherableLane>(
    from span: Span<Lane>,
    indices: SIMD<Lane.Signed>
) -> SIMD<Lane> {
    unsafe SIMD<Lane>.gather(fromUnchecked: span, indices: indices)
}

@Suite("Prototype links")
struct PrototypeLinksTests {
    @Test("The halves of SIMD<UInt8> equal the namespace's and combine back")
    func halvesOfUInt8() {
        let a: SIMD<UInt8> = integerVector(integerPattern)
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<UInt8>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDUInt8.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDUInt8.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDUInt8.combining(SIMDUInt8.upperHalf(a.storage), SIMDUInt8.lowerHalf(a.storage)),
            in: SIMDUInt8.self
        )
    }

    @Test("The halves of SIMD<Int8> equal the namespace's and combine back")
    func halvesOfInt8() {
        let a: SIMD<Int8> = integerVector(integerPattern)
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<Int8>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDInt8.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDInt8.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDInt8.combining(SIMDInt8.upperHalf(a.storage), SIMDInt8.lowerHalf(a.storage)),
            in: SIMDInt8.self
        )
    }

    @Test("The halves of SIMD<UInt16> equal the namespace's and combine back")
    func halvesOfUInt16() {
        let a: SIMD<UInt16> = integerVector(integerPattern)
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<UInt16>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDUInt16.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDUInt16.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDUInt16.combining(SIMDUInt16.upperHalf(a.storage), SIMDUInt16.lowerHalf(a.storage)),
            in: SIMDUInt16.self
        )
    }

    @Test("The halves of SIMD<Int16> equal the namespace's and combine back")
    func halvesOfInt16() {
        let a: SIMD<Int16> = integerVector(integerPattern)
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<Int16>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDInt16.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDInt16.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDInt16.combining(SIMDInt16.upperHalf(a.storage), SIMDInt16.lowerHalf(a.storage)),
            in: SIMDInt16.self
        )
    }

    @Test("The halves of SIMD<UInt32> equal the namespace's and combine back")
    func halvesOfUInt32() {
        let a: SIMD<UInt32> = integerVector(integerPattern)
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<UInt32>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDUInt32.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDUInt32.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDUInt32.combining(SIMDUInt32.upperHalf(a.storage), SIMDUInt32.lowerHalf(a.storage)),
            in: SIMDUInt32.self
        )
    }

    @Test("The halves of SIMD<Int32> equal the namespace's and combine back")
    func halvesOfInt32() {
        let a: SIMD<Int32> = integerVector(integerPattern)
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<Int32>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDInt32.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDInt32.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDInt32.combining(SIMDInt32.upperHalf(a.storage), SIMDInt32.lowerHalf(a.storage)),
            in: SIMDInt32.self
        )
    }

    @Test("The halves of SIMD<Float> equal the namespace's and combine back")
    func halvesOfFloat() {
        let a: SIMD<Float> = floatVector()
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<Float>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDFloat.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDFloat.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDFloat.combining(SIMDFloat.upperHalf(a.storage), SIMDFloat.lowerHalf(a.storage)),
            in: SIMDFloat.self
        )
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @Test("The halves of SIMD<Float16> equal the namespace's and combine back")
    func halvesOfFloat16() {
        let a: SIMD<Float16> = floatVector()
        let (lower, upper, combined) = halves(of: a)
        let half = SIMD<Float16>.laneCount / 2

        #expect(halfLanes(lower.storage) == halfLanes(SIMDFloat16.lowerHalf(a.storage)))
        #expect(halfLanes(upper.storage) == halfLanes(SIMDFloat16.upperHalf(a.storage)))
        #expect(halfLanes(lower.storage) == Array(laneValues(of: a)[..<half]))
        #expect(halfLanes(upper.storage) == Array(laneValues(of: a)[half...]))
        expectEqual(
            combined,
            SIMDFloat16.combining(
                SIMDFloat16.upperHalf(a.storage),
                SIMDFloat16.lowerHalf(a.storage)
            ),
            in: SIMDFloat16.self
        )
    }
    #endif

    @Test("Bit pattern vectors of UInt8 equal the namespace's from every lane type")
    func bitPatternToUInt8() {
        typealias V = SIMD<UInt8>
        typealias H = SIMDUInt8
        let v = LaneVectors(smallPattern)

        expectEqual(V.vector(bitPattern: v.uint8), v.uint8.storage, in: H.self)
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    @Test("Bit pattern vectors of Int8 equal the namespace's from every lane type")
    func bitPatternToInt8() {
        typealias V = SIMD<Int8>
        typealias H = SIMDInt8
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), v.int8.storage, in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    @Test("Bit pattern vectors of UInt16 equal the namespace's from every lane type")
    func bitPatternToUInt16() {
        typealias V = SIMD<UInt16>
        typealias H = SIMDUInt16
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(V.vector(bitPattern: v.uint16), v.uint16.storage, in: H.self)
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    @Test("Bit pattern vectors of Int16 equal the namespace's from every lane type")
    func bitPatternToInt16() {
        typealias V = SIMD<Int16>
        typealias H = SIMDInt16
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int16), v.int16.storage, in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    @Test("Bit pattern vectors of UInt32 equal the namespace's from every lane type")
    func bitPatternToUInt32() {
        typealias V = SIMD<UInt32>
        typealias H = SIMDUInt32
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.uint32), v.uint32.storage, in: H.self)
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    @Test("Bit pattern vectors of Int32 equal the namespace's from every lane type")
    func bitPatternToInt32() {
        typealias V = SIMD<Int32>
        typealias H = SIMDInt32
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int32), v.int32.storage, in: H.self)
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    @Test("Bit pattern vectors of Float equal the namespace's from every lane type")
    func bitPatternToFloat() {
        typealias V = SIMD<Float>
        typealias H = SIMDFloat
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.float), v.float.storage, in: H.self)
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            V.vector(bitPattern: v.float16),
            H.vector(bitPattern: v.float16.storage),
            in: H.self
        )
        #endif
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @Test("Bit pattern vectors of Float16 equal the namespace's from every lane type")
    func bitPatternToFloat16() {
        typealias V = SIMD<Float16>
        typealias H = SIMDFloat16
        let v = LaneVectors(smallPattern)

        expectEqual(
            V.vector(bitPattern: v.uint8),
            H.vector(bitPattern: v.uint8.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.int8), H.vector(bitPattern: v.int8.storage), in: H.self)
        expectEqual(
            V.vector(bitPattern: v.uint16),
            H.vector(bitPattern: v.uint16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int16),
            H.vector(bitPattern: v.int16.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.uint32),
            H.vector(bitPattern: v.uint32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.int32),
            H.vector(bitPattern: v.int32.storage),
            in: H.self
        )
        expectEqual(
            V.vector(bitPattern: v.float),
            H.vector(bitPattern: v.float.storage),
            in: H.self
        )
        expectEqual(V.vector(bitPattern: v.float16), v.float16.storage, in: H.self)
    }
    #endif

    @Test("A generic function reinterprets between lane types as the namespace does")
    func genericBitPattern() {
        let v = LaneVectors(smallPattern)

        expectEqual(
            reinterpreted(v.uint8, as: Int16.self),
            SIMDInt16.vector(bitPattern: v.uint8.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            reinterpreted(v.int16, as: UInt16.self),
            SIMDUInt16.vector(bitPattern: v.int16.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            reinterpreted(v.float, as: UInt32.self),
            SIMDUInt32.vector(bitPattern: v.float.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            reinterpreted(v.uint32, as: Float.self),
            SIMDFloat.vector(bitPattern: v.uint32.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            reinterpreted(v.int32, as: Int32.self),
            v.int32.storage,
            in: SIMDInt32.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            reinterpreted(v.float16, as: Int8.self),
            SIMDInt8.vector(bitPattern: v.float16.storage),
            in: SIMDInt8.self
        )
        expectEqual(
            reinterpreted(v.uint8, as: Float16.self),
            SIMDFloat16.vector(bitPattern: v.uint8.storage),
            in: SIMDFloat16.self
        )
        #endif
    }

    @Test("Rebound masks of SIMD<Lane> equal the namespace's within each width")
    func rebindingMasks() {
        let v = LaneVectors(integerPattern)
        let uint8 = someMask(v.uint8)
        let int8 = someMask(v.int8)
        let uint16 = someMask(v.uint16)
        let int16 = someMask(v.int16)
        let uint32 = someMask(v.uint32)
        let int32 = someMask(v.int32)
        let float = someMask(v.float)

        expectEqual(SIMD<UInt8>.mask(rebinding: uint8), uint8.storage, in: SIMDUInt8.self)
        expectEqual(
            SIMD<UInt8>.mask(rebinding: int8),
            SIMDUInt8.mask(rebinding: int8.storage),
            in: SIMDUInt8.self
        )
        expectEqual(
            SIMD<Int8>.mask(rebinding: uint8),
            SIMDInt8.mask(rebinding: uint8.storage),
            in: SIMDInt8.self
        )
        expectEqual(SIMD<Int8>.mask(rebinding: int8), int8.storage, in: SIMDInt8.self)

        expectEqual(SIMD<UInt16>.mask(rebinding: uint16), uint16.storage, in: SIMDUInt16.self)
        expectEqual(
            SIMD<UInt16>.mask(rebinding: int16),
            SIMDUInt16.mask(rebinding: int16.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<Int16>.mask(rebinding: uint16),
            SIMDInt16.mask(rebinding: uint16.storage),
            in: SIMDInt16.self
        )
        expectEqual(SIMD<Int16>.mask(rebinding: int16), int16.storage, in: SIMDInt16.self)

        expectEqual(SIMD<UInt32>.mask(rebinding: uint32), uint32.storage, in: SIMDUInt32.self)
        expectEqual(
            SIMD<UInt32>.mask(rebinding: int32),
            SIMDUInt32.mask(rebinding: int32.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            SIMD<UInt32>.mask(rebinding: float),
            SIMDUInt32.mask(rebinding: float.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            SIMD<Int32>.mask(rebinding: uint32),
            SIMDInt32.mask(rebinding: uint32.storage),
            in: SIMDInt32.self
        )
        expectEqual(SIMD<Int32>.mask(rebinding: int32), int32.storage, in: SIMDInt32.self)
        expectEqual(
            SIMD<Int32>.mask(rebinding: float),
            SIMDInt32.mask(rebinding: float.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            SIMD<Float>.mask(rebinding: uint32),
            SIMDFloat.mask(rebinding: uint32.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            SIMD<Float>.mask(rebinding: int32),
            SIMDFloat.mask(rebinding: int32.storage),
            in: SIMDFloat.self
        )
        expectEqual(SIMD<Float>.mask(rebinding: float), float.storage, in: SIMDFloat.self)
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @Test("Rebound masks of SIMD<Float16> equal the namespace's within the 16-bit width")
    func rebindingFloat16Masks() {
        let v = LaneVectors(integerPattern)
        let uint16 = someMask(v.uint16)
        let int16 = someMask(v.int16)
        let float16 = someMask(v.float16)

        expectEqual(
            SIMD<UInt16>.mask(rebinding: float16),
            SIMDUInt16.mask(rebinding: float16.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<Int16>.mask(rebinding: float16),
            SIMDInt16.mask(rebinding: float16.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            SIMD<Float16>.mask(rebinding: uint16),
            SIMDFloat16.mask(rebinding: uint16.storage),
            in: SIMDFloat16.self
        )
        expectEqual(
            SIMD<Float16>.mask(rebinding: int16),
            SIMDFloat16.mask(rebinding: int16.storage),
            in: SIMDFloat16.self
        )
        expectEqual(SIMD<Float16>.mask(rebinding: float16), float16.storage, in: SIMDFloat16.self)
    }
    #endif

    @Test("A generic function rebinds masks within a width as the namespace does")
    func genericMaskRebinding() {
        let v = LaneVectors(integerPattern)
        let int16 = someMask(v.int16)
        let float = someMask(v.float)
        let uint8 = someMask(v.uint8)

        expectEqual(
            rebound(int16, to: UInt16.self),
            SIMDUInt16.mask(rebinding: int16.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            rebound(float, to: Int32.self),
            SIMDInt32.mask(rebinding: float.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            rebound(uint8, to: Int8.self),
            SIMDInt8.mask(rebinding: uint8.storage),
            in: SIMDInt8.self
        )
        expectEqual(
            unsignedMask(of: float),
            SIMDUInt32.mask(rebinding: float.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            unsignedMask(of: int16),
            SIMDUInt16.mask(rebinding: int16.storage),
            in: SIMDUInt16.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        let float16 = someMask(v.float16)
        expectEqual(
            rebound(float16, to: Int16.self),
            SIMDInt16.mask(rebinding: float16.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            unsignedMask(of: float16),
            SIMDUInt16.mask(rebinding: float16.storage),
            in: SIMDUInt16.self
        )
        #endif
    }

    @Test("Widening half vectors equals the namespace's for every widenable lane type")
    func wideningHalfVectors() {
        let v = LaneVectors(integerPattern)
        let uint8 = SIMD<UInt8>.upperHalf(v.uint8)
        let int8 = SIMD<Int8>.lowerHalf(v.int8)
        let uint16 = SIMD<UInt16>.upperHalf(v.uint16)
        let int16 = SIMD<Int16>.lowerHalf(v.int16)

        expectEqual(
            SIMD<UInt16>.vector(widening: uint8),
            SIMDUInt16.vector(widening: uint8.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<Int16>.vector(widening: int8),
            SIMDInt16.vector(widening: int8.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            SIMD<UInt32>.vector(widening: uint16),
            SIMDUInt32.vector(widening: uint16.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            SIMD<Int32>.vector(widening: int16),
            SIMDInt32.vector(widening: int16.storage),
            in: SIMDInt32.self
        )
    }

    @Test("A generic function widens from the narrow type and from the wide type")
    func genericWidening() {
        let v = LaneVectors(integerPattern)
        let uint8 = SIMD<UInt8>.upperHalf(v.uint8)
        let int8 = SIMD<Int8>.lowerHalf(v.int8)
        let uint16 = SIMD<UInt16>.upperHalf(v.uint16)
        let int16 = SIMD<Int16>.lowerHalf(v.int16)

        expectEqual(widened(uint8), SIMDUInt16.vector(widening: uint8.storage), in: SIMDUInt16.self)
        expectEqual(widened(int8), SIMDInt16.vector(widening: int8.storage), in: SIMDInt16.self)
        expectEqual(
            widened(uint16),
            SIMDUInt32.vector(widening: uint16.storage),
            in: SIMDUInt32.self
        )
        expectEqual(widened(int16), SIMDInt32.vector(widening: int16.storage), in: SIMDInt32.self)
        expectEqual(
            widened(uint8, to: UInt16.self),
            SIMDUInt16.vector(widening: uint8.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            widened(int8, to: Int16.self),
            SIMDInt16.vector(widening: int8.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            widened(uint16, to: UInt32.self),
            SIMDUInt32.vector(widening: uint16.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            widened(int16, to: Int32.self),
            SIMDInt32.vector(widening: int16.storage),
            in: SIMDInt32.self
        )
    }

    @Test("Multiplying even lanes equals the namespace's for every wide integer lane type")
    func multiplyingEvenLanes() {
        let a = LaneVectors(integerPattern)
        let b = LaneVectors(Array(integerPattern.reversed()))

        expectEqual(
            SIMD<UInt16>.multiplyingEven(a.uint8, b.uint8),
            SIMDUInt16.multiplyingEven(a.uint8.storage, b.uint8.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<Int16>.multiplyingEven(a.int8, b.int8),
            SIMDInt16.multiplyingEven(a.int8.storage, b.int8.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            SIMD<UInt32>.multiplyingEven(a.uint16, b.uint16),
            SIMDUInt32.multiplyingEven(a.uint16.storage, b.uint16.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            SIMD<Int32>.multiplyingEven(a.int16, b.int16),
            SIMDInt32.multiplyingEven(a.int16.storage, b.int16.storage),
            in: SIMDInt32.self
        )
    }

    @Test("A generic function multiplies even lanes from the wide type and from the narrow type")
    func genericMultiplyingEven() {
        let a = LaneVectors(integerPattern)
        let b = LaneVectors(Array(integerPattern.reversed()))

        expectEqual(
            multipliedEven(a.uint8, b.uint8, as: UInt16.self),
            SIMDUInt16.multiplyingEven(a.uint8.storage, b.uint8.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            multipliedEven(a.int16, b.int16, as: Int32.self),
            SIMDInt32.multiplyingEven(a.int16.storage, b.int16.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            multipliedEven(a.uint8, b.uint8),
            SIMDUInt16.multiplyingEven(a.uint8.storage, b.uint8.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            multipliedEven(a.int8, b.int8),
            SIMDInt16.multiplyingEven(a.int8.storage, b.int8.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            multipliedEven(a.uint16, b.uint16),
            SIMDUInt32.multiplyingEven(a.uint16.storage, b.uint16.storage),
            in: SIMDUInt32.self
        )
    }

    @Test("Clamping a wide integer vector to a half vector equals the namespace's for every pair")
    func clampingHalfVectors() {
        let v = LaneVectors(integerPattern)

        #expect(
            halfLanes(SIMD<Int8>.halfVector(clamping: v.uint16).storage)
                == halfLanes(SIMDInt8.halfVector(clamping: v.uint16.storage))
        )
        #expect(
            halfLanes(SIMD<UInt8>.halfVector(clamping: v.uint16).storage)
                == halfLanes(SIMDUInt8.halfVector(clamping: v.uint16.storage))
        )
        #expect(
            halfLanes(SIMD<Int8>.halfVector(clamping: v.int16).storage)
                == halfLanes(SIMDInt8.halfVector(clamping: v.int16.storage))
        )
        #expect(
            halfLanes(SIMD<UInt8>.halfVector(clamping: v.int16).storage)
                == halfLanes(SIMDUInt8.halfVector(clamping: v.int16.storage))
        )
        #expect(
            halfLanes(SIMD<Int16>.halfVector(clamping: v.uint32).storage)
                == halfLanes(SIMDInt16.halfVector(clamping: v.uint32.storage))
        )
        #expect(
            halfLanes(SIMD<UInt16>.halfVector(clamping: v.uint32).storage)
                == halfLanes(SIMDUInt16.halfVector(clamping: v.uint32.storage))
        )
        #expect(
            halfLanes(SIMD<Int16>.halfVector(clamping: v.int32).storage)
                == halfLanes(SIMDInt16.halfVector(clamping: v.int32.storage))
        )
        #expect(
            halfLanes(SIMD<UInt16>.halfVector(clamping: v.int32).storage)
                == halfLanes(SIMDUInt16.halfVector(clamping: v.int32.storage))
        )
    }

    @Test(
        "A generic function clamps to either narrow sibling, from the wide type and the narrow type"
    )
    func genericClamping() {
        let v = LaneVectors(integerPattern)

        #expect(
            halfLanes(clampedToSigned(v.uint16).storage)
                == halfLanes(SIMDInt8.halfVector(clamping: v.uint16.storage))
        )
        #expect(
            halfLanes(clampedToUnsigned(v.uint16).storage)
                == halfLanes(SIMDUInt8.halfVector(clamping: v.uint16.storage))
        )
        #expect(
            halfLanes(clampedToSigned(v.int32).storage)
                == halfLanes(SIMDInt16.halfVector(clamping: v.int32.storage))
        )
        #expect(
            halfLanes(clampedToUnsigned(v.int32).storage)
                == halfLanes(SIMDUInt16.halfVector(clamping: v.int32.storage))
        )
        #expect(
            halfLanes(clamped(v.int16, to: Int8.self).storage)
                == halfLanes(SIMDInt8.halfVector(clamping: v.int16.storage))
        )
        #expect(
            halfLanes(clamped(v.int16, to: UInt8.self).storage)
                == halfLanes(SIMDUInt8.halfVector(clamping: v.int16.storage))
        )
        #expect(
            halfLanes(clamped(v.uint32, to: Int16.self).storage)
                == halfLanes(SIMDInt16.halfVector(clamping: v.uint32.storage))
        )
        #expect(
            halfLanes(clamped(v.uint32, to: UInt16.self).storage)
                == halfLanes(SIMDUInt16.halfVector(clamping: v.uint32.storage))
        )
        #expect(
            halfLanes(clampedFromWide(v.int16, to: Int8.self).storage)
                == halfLanes(SIMDInt8.halfVector(clamping: v.int16.storage))
        )
    }

    @Test("Converting between integers and floats equals the namespace's for every pair")
    func convertingBetweenIntegersAndFloats() {
        let v = LaneVectors(integerPattern)

        expectEqual(
            SIMD<Float>.vector(converting: v.uint32),
            SIMDFloat.vector(converting: v.uint32.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            SIMD<Float>.vector(converting: v.int32),
            SIMDFloat.vector(converting: v.int32.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            SIMD<UInt32>.vector(converting: v.float),
            SIMDUInt32.vector(converting: v.float.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            SIMD<Int32>.vector(converting: v.float),
            SIMDInt32.vector(converting: v.float.storage),
            in: SIMDInt32.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            SIMD<Float16>.vector(converting: v.uint16),
            SIMDFloat16.vector(converting: v.uint16.storage),
            in: SIMDFloat16.self
        )
        expectEqual(
            SIMD<Float16>.vector(converting: v.int16),
            SIMDFloat16.vector(converting: v.int16.storage),
            in: SIMDFloat16.self
        )
        expectEqual(
            SIMD<UInt16>.vector(converting: v.float16),
            SIMDUInt16.vector(converting: v.float16.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<Int16>.vector(converting: v.float16),
            SIMDInt16.vector(converting: v.float16.storage),
            in: SIMDInt16.self
        )
        #endif
    }

    @Test("A generic function converts between a float and its integers")
    func genericConverting() {
        let v = LaneVectors(integerPattern)

        expectEqual(
            converted(v.int32, to: Float.self),
            SIMDFloat.vector(converting: v.int32.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            converted(v.uint32, to: Float.self),
            SIMDFloat.vector(converting: v.uint32.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            converted(v.float, to: Int32.self),
            SIMDInt32.vector(converting: v.float.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            converted(v.float, to: UInt32.self),
            SIMDUInt32.vector(converting: v.float.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            convertedToSigned(v.float),
            SIMDInt32.vector(converting: v.float.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            convertedFromSigned(v.int32) as SIMD<Float>,
            SIMDFloat.vector(converting: v.int32.storage),
            in: SIMDFloat.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            converted(v.int16, to: Float16.self),
            SIMDFloat16.vector(converting: v.int16.storage),
            in: SIMDFloat16.self
        )
        expectEqual(
            converted(v.float16, to: UInt16.self),
            SIMDUInt16.vector(converting: v.float16.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            convertedToSigned(v.float16),
            SIMDInt16.vector(converting: v.float16.storage),
            in: SIMDInt16.self
        )
        #endif
    }

    @Test("Rounding a float vector to nearest even equals the namespace's for each float")
    func roundingToNearestOrEvenLanes() {
        let v = LaneVectors(integerPattern)

        expectEqual(
            SIMD<Int32>.vector(roundingToNearestOrEven: v.float),
            SIMDInt32.vector(roundingToNearestOrEven: v.float.storage),
            in: SIMDInt32.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            SIMD<Int16>.vector(roundingToNearestOrEven: v.float16),
            SIMDInt16.vector(roundingToNearestOrEven: v.float16.storage),
            in: SIMDInt16.self
        )
        #endif
    }

    @Test("A generic function rounds a float vector to nearest even")
    func genericRounding() {
        let v = LaneVectors(integerPattern)

        expectEqual(
            rounded(v.float),
            SIMDInt32.vector(roundingToNearestOrEven: v.float.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            rounded(v.float, to: Int32.self),
            SIMDInt32.vector(roundingToNearestOrEven: v.float.storage),
            in: SIMDInt32.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectEqual(
            rounded(v.float16),
            SIMDInt16.vector(roundingToNearestOrEven: v.float16.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            rounded(v.float16, to: Int16.self),
            SIMDInt16.vector(roundingToNearestOrEven: v.float16.storage),
            in: SIMDInt16.self
        )
        #endif
    }

    @Test("Truncating an unsigned wide vector equals the namespace's, signed or unsigned witness")
    func truncatingHalfVectors() {
        let v = LaneVectors(integerPattern)

        #expect(
            halfLanes(SIMD<UInt8>.halfVector(truncatingIfNeeded: v.uint16).storage)
                == halfLanes(SIMDUInt8.halfVector(truncatingIfNeeded: v.uint16.storage))
        )
        #expect(
            halfLanes(SIMD<UInt16>.halfVector(truncatingIfNeeded: v.uint32).storage)
                == halfLanes(SIMDUInt16.halfVector(truncatingIfNeeded: v.uint32.storage))
        )
        #expect(
            halfLanes(Int16._truncatedHalf(v.uint16).storage)
                == halfLanes(SIMDUInt8.halfVector(truncatingIfNeeded: v.uint16.storage))
        )
        #expect(
            halfLanes(UInt16._truncatedHalf(v.uint16).storage)
                == halfLanes(SIMDUInt8.halfVector(truncatingIfNeeded: v.uint16.storage))
        )
        #expect(
            halfLanes(Int32._truncatedHalf(v.uint32).storage)
                == halfLanes(SIMDUInt16.halfVector(truncatingIfNeeded: v.uint32.storage))
        )
    }

    @Test("A generic function truncates an unsigned wide vector")
    func genericTruncating() {
        let v = LaneVectors(integerPattern)

        #expect(
            halfLanes(truncated(v.uint16).storage)
                == halfLanes(SIMDUInt8.halfVector(truncatingIfNeeded: v.uint16.storage))
        )
        #expect(
            halfLanes(truncated(v.uint32).storage)
                == halfLanes(SIMDUInt16.halfVector(truncatingIfNeeded: v.uint32.storage))
        )
        #expect(
            halfLanes(truncated(v.uint16, to: UInt8.self).storage)
                == halfLanes(SIMDUInt8.halfVector(truncatingIfNeeded: v.uint16.storage))
        )
        #expect(
            halfLanes(truncated(v.uint32, to: UInt16.self).storage)
                == halfLanes(SIMDUInt16.halfVector(truncatingIfNeeded: v.uint32.storage))
        )
    }

    @Test("Narrowing masks of any source with the same unsigned width equals the namespace's")
    func narrowingMasks() {
        let v = LaneVectors(integerPattern)
        let w = LaneVectors(smallPattern)
        let a = (
            uint16: someMask(v.uint16), int16: someMask(v.int16), uint32: someMask(v.uint32),
            int32: someMask(v.int32), float: someMask(v.float)
        )
        let b = (
            uint16: someMask(w.uint16), int16: someMask(w.int16), uint32: someMask(w.uint32),
            int32: someMask(w.int32), float: someMask(w.float)
        )

        expectEqual(
            SIMD<UInt8>.mask(narrowing: a.uint16, b.uint16),
            SIMDUInt8.mask(narrowing: a.uint16.storage, b.uint16.storage),
            in: SIMDUInt8.self
        )
        expectEqual(
            SIMD<UInt8>.mask(narrowing: a.int16, b.int16),
            SIMDUInt8.mask(narrowing: a.int16.storage, b.int16.storage),
            in: SIMDUInt8.self
        )
        expectEqual(
            SIMD<Int8>.mask(narrowing: a.uint16, b.uint16),
            SIMDInt8.mask(narrowing: a.uint16.storage, b.uint16.storage),
            in: SIMDInt8.self
        )
        expectEqual(
            SIMD<Int8>.mask(narrowing: a.int16, b.int16),
            SIMDInt8.mask(narrowing: a.int16.storage, b.int16.storage),
            in: SIMDInt8.self
        )
        expectEqual(
            SIMD<UInt16>.mask(narrowing: a.uint32, b.uint32),
            SIMDUInt16.mask(narrowing: a.uint32.storage, b.uint32.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<UInt16>.mask(narrowing: a.int32, b.int32),
            SIMDUInt16.mask(narrowing: a.int32.storage, b.int32.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<UInt16>.mask(narrowing: a.float, b.float),
            SIMDUInt16.mask(narrowing: a.float.storage, b.float.storage),
            in: SIMDUInt16.self
        )
        expectEqual(
            SIMD<Int16>.mask(narrowing: a.uint32, b.uint32),
            SIMDInt16.mask(narrowing: a.uint32.storage, b.uint32.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            SIMD<Int16>.mask(narrowing: a.int32, b.int32),
            SIMDInt16.mask(narrowing: a.int32.storage, b.int32.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            SIMD<Int16>.mask(narrowing: a.float, b.float),
            SIMDInt16.mask(narrowing: a.float.storage, b.float.storage),
            in: SIMDInt16.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        let a16 = someMask(v.float16)
        let b16 = someMask(w.float16)
        expectEqual(
            SIMD<UInt8>.mask(narrowing: a16, b16),
            SIMDUInt8.mask(narrowing: a16.storage, b16.storage),
            in: SIMDUInt8.self
        )
        expectEqual(
            SIMD<Int8>.mask(narrowing: a16, b16),
            SIMDInt8.mask(narrowing: a16.storage, b16.storage),
            in: SIMDInt8.self
        )
        #endif
    }

    @Test("A generic function narrows masks from the source type and from the wide type")
    func genericMaskNarrowing() {
        let v = LaneVectors(integerPattern)
        let w = LaneVectors(smallPattern)
        let (a16, b16) = (someMask(v.int16), someMask(w.int16))
        let (a32, b32) = (someMask(v.float), someMask(w.float))

        expectEqual(
            narrowed(a16, b16, to: UInt8.self),
            SIMDUInt8.mask(narrowing: a16.storage, b16.storage),
            in: SIMDUInt8.self
        )
        expectEqual(
            narrowed(a32, b32, to: Int16.self),
            SIMDInt16.mask(narrowing: a32.storage, b32.storage),
            in: SIMDInt16.self
        )
        expectEqual(
            narrowedFromWide(someMask(v.int16), someMask(w.int16), to: Int8.self),
            SIMDInt8.mask(narrowing: someMask(v.int16).storage, someMask(w.int16).storage),
            in: SIMDInt8.self
        )
        expectEqual(
            narrowedFromWide(someMask(v.uint32), someMask(w.uint32), to: UInt16.self),
            SIMDUInt16.mask(narrowing: someMask(v.uint32).storage, someMask(w.uint32).storage),
            in: SIMDUInt16.self
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        let (a, b) = (someMask(v.float16), someMask(w.float16))
        expectEqual(
            narrowed(a, b, to: Int8.self),
            SIMDInt8.mask(narrowing: a.storage, b.storage),
            in: SIMDInt8.self
        )
        #endif
    }

    @Test("Gathering equals the namespace's for every gatherable lane type")
    func gatheringLanes() {
        let indices = gatherIndices()
        let uint32Table = ContiguousArray((0..<64).map { UInt32($0 * 3 + 1) })
        let int32Table = ContiguousArray((0..<64).map { Int32($0 * 5) - 100 })
        let floatTable = ContiguousArray((0..<64).map { Float($0) * 0.25 - 3 })

        expectEqual(
            SIMD<UInt32>.gather(from: uint32Table.span, indices: indices),
            SIMDUInt32.gather(from: uint32Table.span, indices: indices.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            SIMD<Int32>.gather(from: int32Table.span, indices: indices),
            SIMDInt32.gather(from: int32Table.span, indices: indices.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            SIMD<Float>.gather(from: floatTable.span, indices: indices),
            SIMDFloat.gather(from: floatTable.span, indices: indices.storage),
            in: SIMDFloat.self
        )

        let unchecked = (
            uint32: unsafe SIMD<UInt32>.gather(fromUnchecked: uint32Table.span, indices: indices),
            int32: unsafe SIMD<Int32>.gather(fromUnchecked: int32Table.span, indices: indices),
            float: unsafe SIMD<Float>.gather(fromUnchecked: floatTable.span, indices: indices)
        )
        expectEqual(
            unchecked.uint32,
            unsafe SIMDUInt32.gather(fromUnchecked: uint32Table.span, indices: indices.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            unchecked.int32,
            unsafe SIMDInt32.gather(fromUnchecked: int32Table.span, indices: indices.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            unchecked.float,
            unsafe SIMDFloat.gather(fromUnchecked: floatTable.span, indices: indices.storage),
            in: SIMDFloat.self
        )

        uint32Table.withUnsafeBufferPointer { table in
            expectEqual(
                unsafe SIMD<UInt32>.gather(from: table.baseAddress!, indices: indices),
                unsafe SIMDUInt32.gather(from: table.baseAddress!, indices: indices.storage),
                in: SIMDUInt32.self
            )
        }
        int32Table.withUnsafeBufferPointer { table in
            expectEqual(
                unsafe SIMD<Int32>.gather(from: table.baseAddress!, indices: indices),
                unsafe SIMDInt32.gather(from: table.baseAddress!, indices: indices.storage),
                in: SIMDInt32.self
            )
        }
        floatTable.withUnsafeBufferPointer { table in
            expectEqual(
                unsafe SIMD<Float>.gather(from: table.baseAddress!, indices: indices),
                unsafe SIMDFloat.gather(from: table.baseAddress!, indices: indices.storage),
                in: SIMDFloat.self
            )
        }
    }

    @Test("A generic function gathers over a span, a pointer and an unchecked span")
    func genericGathering() {
        let indices = gatherIndices()
        let int32Table = ContiguousArray((0..<64).map { Int32($0 * 5) - 100 })
        let floatTable = ContiguousArray((0..<64).map { Float($0) * 0.25 - 3 })
        let uint32Table = ContiguousArray((0..<64).map { UInt32($0 * 3 + 1) })

        expectEqual(
            gathered(from: int32Table.span, indices: indices),
            SIMDInt32.gather(from: int32Table.span, indices: indices.storage),
            in: SIMDInt32.self
        )
        expectEqual(
            gathered(from: floatTable.span, indices: indices),
            SIMDFloat.gather(from: floatTable.span, indices: indices.storage),
            in: SIMDFloat.self
        )
        expectEqual(
            gathered(from: uint32Table.span, indices: indices),
            SIMDUInt32.gather(from: uint32Table.span, indices: indices.storage),
            in: SIMDUInt32.self
        )
        expectEqual(
            gatheredUnchecked(from: floatTable.span, indices: indices),
            unsafe SIMDFloat.gather(fromUnchecked: floatTable.span, indices: indices.storage),
            in: SIMDFloat.self
        )
        floatTable.withUnsafeBufferPointer { table in
            unsafe expectEqual(
                gathered(from: table.baseAddress!, indices: indices),
                unsafe SIMDFloat.gather(from: table.baseAddress!, indices: indices.storage),
                in: SIMDFloat.self
            )
        }
        int32Table.withUnsafeBufferPointer { table in
            unsafe expectEqual(
                gathered(from: table.baseAddress!, indices: indices),
                unsafe SIMDInt32.gather(from: table.baseAddress!, indices: indices.storage),
                in: SIMDInt32.self
            )
        }
    }
}
