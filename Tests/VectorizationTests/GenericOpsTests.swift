import Testing
import Vectorization

private func elementOps<Lane: SIMDElement>(
    _ input: ContiguousArray<Lane>
) -> (laneCount: Int, copy: [Lane], zero: SIMD<Lane>) {
    typealias H = SIMD<Lane>

    let copy = ContiguousArray<Lane>(capacity: H.laneCount) { output in
        H.append(H.load(from: input.span), to: &output)
    }
    return (H.laneCount, Array(copy), H.zero())
}

private func numericOps<Lane: SIMDNumericElement>(
    _ a: SIMD<Lane>,
    _ b: SIMD<Lane>
) -> (sum: SIMD<Lane>, smaller: SIMD<Lane>, count: Int, lane: Lane, uncheckedLane: Lane) {
    typealias H = SIMD<Lane>

    let isSmaller = H.lessThan(a, b)
    return (
        H.adding(a, b), H.selecting(isSmaller, a, b), H.trueCount(isSmaller), H.lane(a, at: 1),
        unsafe H.lane(a, atUnchecked: 1)
    )
}

private func integerOps<Lane: SIMDIntegerElement>(
    _ a: SIMD<Lane>
) -> (shifted: SIMD<Lane>, inverted: SIMD<Lane>, saturated: SIMD<Lane>) {
    typealias H = SIMD<Lane>

    return (H.shiftedLeft(a, by: 1), H.bitwiseNot(a), H.saturatingAdding(a, a))
}

private func floatOps<Lane: SIMDFloatElement>(
    _ a: SIMD<Lane>
) -> (root: SIMD<Lane>, rounded: SIMD<Lane>, negated: SIMD<Lane>) {
    typealias H = SIMD<Lane>

    return (H.squareRoot(H.magnitude(a)), H.roundedDown(a), H.negated(a))
}

@Suite("Generic ops")
struct GenericOpsTests {
    @Test("Ops of SIMDElement called through a generic lane type match the concrete ones")
    func elementOpsMatchConcreteOnes() {
        let bytes = ContiguousArray(
            (0..<SIMD<UInt8>.laneCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        )
        let genericBytes = elementOps(bytes)
        let concreteBytes = ContiguousArray<UInt8>(capacity: SIMD<UInt8>.laneCount) { output in
            SIMD<UInt8>.append(SIMD<UInt8>.load(from: bytes.span), to: &output)
        }

        #expect(genericBytes.laneCount == SIMD<UInt8>.laneCount)
        #expect(genericBytes.copy == Array(concreteBytes))
        #expect(genericBytes.copy == Array(bytes))
        #expect(genericBytes.zero.raw == SIMD<UInt8>.zero().raw)

        let floats = ContiguousArray((0..<SIMD<Float>.laneCount).map { Float($0) * 1.5 - 4 })
        let genericFloats = elementOps(floats)
        let concreteFloats = ContiguousArray<Float>(capacity: SIMD<Float>.laneCount) { output in
            SIMD<Float>.append(SIMD<Float>.load(from: floats.span), to: &output)
        }

        #expect(genericFloats.laneCount == SIMD<Float>.laneCount)
        #expect(genericFloats.copy == Array(concreteFloats))
        #expect(genericFloats.copy == Array(floats))
        #expect(genericFloats.zero.raw == SIMD<Float>.zero().raw)

        let brains = ContiguousArray(
            (0..<SIMD<BFloat16>.laneCount).map { BFloat16(Float($0) * 0.5) }
        )
        let genericBrains = elementOps(brains)
        let concreteBrains = ContiguousArray<BFloat16>(capacity: SIMD<BFloat16>.laneCount) {
            output in
            SIMD<BFloat16>.append(SIMD<BFloat16>.load(from: brains.span), to: &output)
        }

        #expect(genericBrains.laneCount == SIMD<BFloat16>.laneCount)
        #expect(genericBrains.copy == Array(concreteBrains))
        #expect(genericBrains.copy == Array(brains))
        #expect(genericBrains.zero.raw == SIMD<BFloat16>.zero().raw)
    }

    @Test("Ops of SIMDNumericElement called through a generic lane type match the concrete ones")
    func numericOpsMatchConcreteOnes() {
        let (shorts, others) = (SIMD<Int16>.iota(-2), SIMD<Int16>.repeating(3))
        let genericShorts = numericOps(shorts, others)
        let isSmaller = SIMD<Int16>.lessThan(shorts, others)

        #expect(genericShorts.sum.raw == SIMD<Int16>.adding(shorts, others).raw)
        #expect(genericShorts.smaller.raw == SIMD<Int16>.selecting(isSmaller, shorts, others).raw)
        #expect(genericShorts.count == SIMD<Int16>.trueCount(isSmaller))
        #expect(genericShorts.lane == SIMD<Int16>.lane(shorts, at: 1))
        let uncheckedShort = unsafe SIMD<Int16>.lane(shorts, atUnchecked: 1)
        #expect(genericShorts.uncheckedLane == uncheckedShort)

        let (floats, otherFloats) = (SIMD<Float>.iota(-2.5), SIMD<Float>.repeating(1.25))
        let genericFloats = numericOps(floats, otherFloats)
        let isSmallerFloat = SIMD<Float>.lessThan(floats, otherFloats)

        #expect(genericFloats.sum.raw == SIMD<Float>.adding(floats, otherFloats).raw)
        #expect(
            genericFloats.smaller.raw
                == SIMD<Float>.selecting(isSmallerFloat, floats, otherFloats).raw
        )
        #expect(genericFloats.count == SIMD<Float>.trueCount(isSmallerFloat))
        #expect(genericFloats.lane == SIMD<Float>.lane(floats, at: 1))
        let uncheckedFloat = unsafe SIMD<Float>.lane(floats, atUnchecked: 1)
        #expect(genericFloats.uncheckedLane == uncheckedFloat)
    }

    @Test("Ops of SIMDIntegerElement called through a generic lane type match the concrete ones")
    func integerOpsMatchConcreteOnes() {
        let bytes = SIMD<UInt8>.iota(100)
        let genericBytes = integerOps(bytes)

        #expect(genericBytes.shifted.raw == SIMD<UInt8>.shiftedLeft(bytes, by: 1).raw)
        #expect(genericBytes.inverted.raw == SIMD<UInt8>.bitwiseNot(bytes).raw)
        #expect(genericBytes.saturated.raw == SIMD<UInt8>.saturatingAdding(bytes, bytes).raw)

        let words = SIMD<Int32>.iota(-3)
        let genericWords = integerOps(words)

        #expect(genericWords.shifted.raw == SIMD<Int32>.shiftedLeft(words, by: 1).raw)
        #expect(genericWords.inverted.raw == SIMD<Int32>.bitwiseNot(words).raw)
        #expect(genericWords.saturated.raw == SIMD<Int32>.saturatingAdding(words, words).raw)
    }

    @Test("Ops of SIMDFloatElement called through a generic lane type match the concrete ones")
    func floatOpsMatchConcreteOnes() {
        let floats = SIMD<Float>.iota(-5.5)
        let genericFloats = floatOps(floats)

        #expect(
            genericFloats.root.raw == SIMD<Float>.squareRoot(SIMD<Float>.magnitude(floats)).raw
        )
        #expect(genericFloats.rounded.raw == SIMD<Float>.roundedDown(floats).raw)
        #expect(genericFloats.negated.raw == SIMD<Float>.negated(floats).raw)

        let doubles = SIMD<Double>.iota(-1.5)
        let genericDoubles = floatOps(doubles)

        #expect(
            genericDoubles.root.raw == SIMD<Double>.squareRoot(SIMD<Double>.magnitude(doubles)).raw
        )
        #expect(genericDoubles.rounded.raw == SIMD<Double>.roundedDown(doubles).raw)
        #expect(genericDoubles.negated.raw == SIMD<Double>.negated(doubles).raw)
    }
}
