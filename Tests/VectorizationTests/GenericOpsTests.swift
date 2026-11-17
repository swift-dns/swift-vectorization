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

private func expectHalfAndBlockOps<Lane: SIMDElement & Equatable>(
    _ input: ContiguousArray<Lane>
) {
    typealias H = SIMD<Lane>

    func appended(_ body: (inout OutputSpan<Lane>) -> Void) -> [Lane] {
        Array(ContiguousArray<Lane>(capacity: H.laneCount, initializingWith: body))
    }

    let a = H.load(from: input.span)
    let lower = Array(input[..<(H.laneCount / 2)])
    let upper = Array(input[(H.laneCount / 2)...])
    let blockLanes = H.laneCount / H.blockCount
    let firstBlock = Array(input[..<blockLanes])
    let lastBlock = Array(input[(H.laneCount - blockLanes)...])
    let replaced = Array(input[..<(H.laneCount - blockLanes)]) + firstBlock

    #expect(appended { H.append(H.lowerHalf(a), to: &$0) } == lower, "\(H.self) lower half")
    #expect(appended { H.append(H.upperHalf(a), to: &$0) } == upper, "\(H.self) upper half")
    #expect(appended { H.append(H.loadHalf(from: input.span), to: &$0) } == lower)
    let extended = H.zeroExtending(H.lowerHalf(a))
    let zeros = appended { H.append(H.zero(), to: &$0) }
    #expect(
        appended { H.append(extended, to: &$0) } == lower + zeros[..<upper.count],
        "\(H.self) zero-extended half"
    )
    let swapped = H.combining(H.lowerHalf(a), H.upperHalf(a))
    #expect(appended { H.append(swapped, to: &$0) } == upper + lower, "\(H.self) combined halves")
    let extracted = H.block(a, at: H.blockCount - 1)
    #expect(appended { H.append(extracted, to: &$0) } == lastBlock, "\(H.self) last block")
    #expect(appended { H.append(H.loadBlock(from: input.span), to: &$0) } == firstBlock)
    let replacing = H.replacingBlock(a, at: H.blockCount - 1, with: H.block(a, at: 0))
    #expect(appended { H.append(replacing, to: &$0) } == replaced, "\(H.self) replaced block")
}

private func halfMaskOps<Lane: SIMDNumericElement>(
    _ mask: SIMD<Lane>.Mask
) -> (upper: SIMD<Lane>.HalfMask, combined: SIMD<Lane>.Mask) {
    typealias H = SIMD<Lane>

    let upper = H.upperHalf(mask)
    return (upper, H.combining(H.lowerHalf(mask), upper))
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

private func signedOps<Lane: SIMDSignedElement>(
    _ a: SIMD<Lane>
) -> (negated: SIMD<Lane>, magnitude: SIMD<Lane>, signs: SIMD<Lane>.Mask, zeroed: SIMD<Lane>) {
    typealias H = SIMD<Lane>

    return (H.negated(a), H.magnitude(a), H.isNegative(a), H.zeroingNegative(a))
}

private func unsignedIntegerOps<Lane: SIMDUnsignedIntegerElement>(
    _ a: SIMD<Lane>
) -> (bitCounts: SIMD<Lane>, halved: SIMD<Lane>) {
    typealias H = SIMD<Lane>

    let bitCounts = H.nonzeroBitCount(a)
    return (bitCounts, H.shiftedRight(bitCounts, by: 1))
}

private func signedIntegerOps<Lane: SIMDSignedIntegerElement>(
    _ a: SIMD<Lane>
) -> (saturated: SIMD<Lane>, magnitude: SIMD<Lane>, signs: SIMD<Lane>, masked: SIMD<Lane>) {
    typealias H = SIMD<Lane>

    return (
        H.saturatingNegated(a), H.saturatingMagnitude(a), H.broadcastingSignBit(a),
        H.magnitude(a, where: H.isNegative(a))
    )
}

private func quarterVectorOps<Lane: SIMDQuarterVectorElement>(
    _ input: ContiguousArray<Lane>
) -> [Lane] {
    typealias H = SIMD<Lane>

    let copy = ContiguousArray<Lane>(capacity: H.laneCount) { output in
        H.append(H.loadQuarter(from: input.span), to: &output)
    }
    return Array(copy)
}

private func eighthVectorOps<Lane: SIMDEighthVectorElement>(
    _ input: ContiguousArray<Lane>
) -> (eighth: [Lane], quarter: [Lane]) {
    typealias H = SIMD<Lane>

    let eighth = ContiguousArray<Lane>(capacity: H.laneCount) { output in
        H.append(H.loadEighth(from: input.span), to: &output)
    }
    let quarter = ContiguousArray<Lane>(capacity: H.laneCount) { output in
        H.append(H.loadQuarter(from: input.span), to: &output)
    }
    return (Array(eighth), Array(quarter))
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
        #expect(genericBytes.zero.simd == SIMD<UInt8>.zero().simd)

        let floats = ContiguousArray((0..<SIMD<Float>.laneCount).map { Float($0) * 1.5 - 4 })
        let genericFloats = elementOps(floats)
        let concreteFloats = ContiguousArray<Float>(capacity: SIMD<Float>.laneCount) { output in
            SIMD<Float>.append(SIMD<Float>.load(from: floats.span), to: &output)
        }

        #expect(genericFloats.laneCount == SIMD<Float>.laneCount)
        #expect(genericFloats.copy == Array(concreteFloats))
        #expect(genericFloats.copy == Array(floats))
        #expect(genericFloats.zero.simd == SIMD<Float>.zero().simd)

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
        #expect(genericBrains.zero.simd == SIMD<BFloat16>.zero().simd)
    }

    @Test("Half and block ops of SIMDElement called through a generic lane type match the lanes")
    func halfAndBlockOpsMatchLanes() {
        expectHalfAndBlockOps(
            ContiguousArray(
                (0..<SIMD<UInt8>.laneCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
            )
        )
        expectHalfAndBlockOps(
            ContiguousArray((0..<SIMD<Float>.laneCount).map { Float($0) * 1.5 - 4 })
        )
        expectHalfAndBlockOps(
            ContiguousArray((0..<SIMD<Int64>.laneCount).map { Int64($0) &* 1_000_003 &- 7 })
        )
        expectHalfAndBlockOps(
            ContiguousArray((0..<SIMD<BFloat16>.laneCount).map { BFloat16(Float($0) * 0.5) })
        )
    }

    @Test(
        "Half mask ops of SIMDNumericElement called through a generic lane type match the concrete ones"
    )
    func halfMaskOpsMatchConcreteOnes() {
        let shorts = SIMD<Int16>.iota(0)
        let mask = SIMD<Int16>.lessThan(shorts, SIMD<Int16>.repeating(5))
        let generic = halfMaskOps(mask)
        let concreteUpper = SIMD<Int16>.upperHalf(mask)
        let concreteCombined = SIMD<Int16>.combining(SIMD<Int16>.lowerHalf(mask), concreteUpper)

        #expect(SIMD<Int16>.bits(of: generic.combined) == SIMD<Int16>.bits(of: concreteCombined))
        #expect(
            SIMD<Int16>.bits(of: SIMD<Int16>.combining(generic.upper, generic.upper))
                == SIMD<Int16>.bits(of: SIMD<Int16>.combining(concreteUpper, concreteUpper))
        )

        let floats = SIMD<Float>.iota(0)
        let floatMask = SIMD<Float>.greaterThan(floats, SIMD<Float>.repeating(1))
        let genericFloats = halfMaskOps(floatMask)
        let floatUpper = SIMD<Float>.upperHalf(floatMask)
        let floatCombined = SIMD<Float>.combining(SIMD<Float>.lowerHalf(floatMask), floatUpper)

        #expect(
            SIMD<Float>.bits(of: genericFloats.combined) == SIMD<Float>.bits(of: floatCombined)
        )
    }

    @Test("Ops of SIMDNumericElement called through a generic lane type match the concrete ones")
    func numericOpsMatchConcreteOnes() {
        let (shorts, others) = (SIMD<Int16>.iota(-2), SIMD<Int16>.repeating(3))
        let genericShorts = numericOps(shorts, others)
        let isSmaller = SIMD<Int16>.lessThan(shorts, others)

        #expect(genericShorts.sum.simd == SIMD<Int16>.adding(shorts, others).simd)
        #expect(genericShorts.smaller.simd == SIMD<Int16>.selecting(isSmaller, shorts, others).simd)
        #expect(genericShorts.count == SIMD<Int16>.trueCount(isSmaller))
        #expect(genericShorts.lane == SIMD<Int16>.lane(shorts, at: 1))
        let uncheckedShort = unsafe SIMD<Int16>.lane(shorts, atUnchecked: 1)
        #expect(genericShorts.uncheckedLane == uncheckedShort)

        let (floats, otherFloats) = (SIMD<Float>.iota(-2.5), SIMD<Float>.repeating(1.25))
        let genericFloats = numericOps(floats, otherFloats)
        let isSmallerFloat = SIMD<Float>.lessThan(floats, otherFloats)

        #expect(genericFloats.sum.simd == SIMD<Float>.adding(floats, otherFloats).simd)
        #expect(
            genericFloats.smaller.simd
                == SIMD<Float>.selecting(isSmallerFloat, floats, otherFloats).simd
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

        #expect(genericBytes.shifted.simd == SIMD<UInt8>.shiftedLeft(bytes, by: 1).simd)
        #expect(genericBytes.inverted.simd == SIMD<UInt8>.bitwiseNot(bytes).simd)
        #expect(genericBytes.saturated.simd == SIMD<UInt8>.saturatingAdding(bytes, bytes).simd)

        let words = SIMD<Int32>.iota(-3)
        let genericWords = integerOps(words)

        #expect(genericWords.shifted.simd == SIMD<Int32>.shiftedLeft(words, by: 1).simd)
        #expect(genericWords.inverted.simd == SIMD<Int32>.bitwiseNot(words).simd)
        #expect(genericWords.saturated.simd == SIMD<Int32>.saturatingAdding(words, words).simd)
    }

    @Test("Ops of SIMDFloatElement called through a generic lane type match the concrete ones")
    func floatOpsMatchConcreteOnes() {
        let floats = SIMD<Float>.iota(-5.5)
        let genericFloats = floatOps(floats)

        #expect(
            genericFloats.root.simd == SIMD<Float>.squareRoot(SIMD<Float>.magnitude(floats)).simd
        )
        #expect(genericFloats.rounded.simd == SIMD<Float>.roundedDown(floats).simd)
        #expect(genericFloats.negated.simd == SIMD<Float>.negated(floats).simd)

        let doubles = SIMD<Double>.iota(-1.5)
        let genericDoubles = floatOps(doubles)

        #expect(
            genericDoubles.root.simd
                == SIMD<Double>.squareRoot(SIMD<Double>.magnitude(doubles)).simd
        )
        #expect(genericDoubles.rounded.simd == SIMD<Double>.roundedDown(doubles).simd)
        #expect(genericDoubles.negated.simd == SIMD<Double>.negated(doubles).simd)
    }

    @Test("Ops of SIMDSignedElement called through a generic lane type match the concrete ones")
    func signedOpsMatchConcreteOnes() {
        let shorts = SIMD<Int16>.iota(-3)
        let genericShorts = signedOps(shorts)

        #expect(genericShorts.negated.simd == SIMD<Int16>.negated(shorts).simd)
        #expect(genericShorts.magnitude.simd == SIMD<Int16>.magnitude(shorts).simd)
        #expect(genericShorts.signs.simd == SIMD<Int16>.isNegative(shorts).simd)
        #expect(genericShorts.zeroed.simd == SIMD<Int16>.zeroingNegative(shorts).simd)

        let floats = SIMD<Float>.iota(-2.5)
        let genericFloats = signedOps(floats)

        #expect(genericFloats.negated.simd == SIMD<Float>.negated(floats).simd)
        #expect(genericFloats.magnitude.simd == SIMD<Float>.magnitude(floats).simd)
        #expect(genericFloats.signs.simd == SIMD<Float>.isNegative(floats).simd)
        #expect(genericFloats.zeroed.simd == SIMD<Float>.zeroingNegative(floats).simd)
    }

    @Test(
        "Ops of SIMDUnsignedIntegerElement called through a generic lane type match the concrete ones"
    )
    func unsignedIntegerOpsMatchConcreteOnes() {
        let bytes = SIMD<UInt8>.iota(250)
        let genericBytes = unsignedIntegerOps(bytes)
        let byteCounts = SIMD<UInt8>.nonzeroBitCount(bytes)

        #expect(genericBytes.bitCounts.simd == byteCounts.simd)
        #expect(genericBytes.halved.simd == SIMD<UInt8>.shiftedRight(byteCounts, by: 1).simd)

        let words = SIMD<UInt32>.iota(0xFFFF_FFFE)
        let genericWords = unsignedIntegerOps(words)
        let wordCounts = SIMD<UInt32>.nonzeroBitCount(words)

        #expect(genericWords.bitCounts.simd == wordCounts.simd)
        #expect(genericWords.halved.simd == SIMD<UInt32>.shiftedRight(wordCounts, by: 1).simd)
    }

    @Test(
        "Ops of SIMDSignedIntegerElement called through a generic lane type match the concrete ones"
    )
    func signedIntegerOpsMatchConcreteOnes() {
        let bytes = SIMD<Int8>.iota(-128)
        let genericBytes = signedIntegerOps(bytes)

        #expect(genericBytes.saturated.simd == SIMD<Int8>.saturatingNegated(bytes).simd)
        #expect(genericBytes.magnitude.simd == SIMD<Int8>.saturatingMagnitude(bytes).simd)
        #expect(genericBytes.signs.simd == SIMD<Int8>.broadcastingSignBit(bytes).simd)
        let maskedBytes = SIMD<Int8>.magnitude(bytes, where: SIMD<Int8>.isNegative(bytes))
        #expect(genericBytes.masked.simd == maskedBytes.simd)

        let words = SIMD<Int32>.iota(-3)
        let genericWords = signedIntegerOps(words)

        #expect(genericWords.saturated.simd == SIMD<Int32>.saturatingNegated(words).simd)
        #expect(genericWords.magnitude.simd == SIMD<Int32>.saturatingMagnitude(words).simd)
        #expect(genericWords.signs.simd == SIMD<Int32>.broadcastingSignBit(words).simd)
        let maskedWords = SIMD<Int32>.magnitude(words, where: SIMD<Int32>.isNegative(words))
        #expect(genericWords.masked.simd == maskedWords.simd)
    }

    @Test(
        "Ops of SIMDQuarterVectorElement called through a generic lane type match the concrete ones"
    )
    func quarterVectorOpsMatchConcreteOnes() {
        let shorts = ContiguousArray(
            (0..<SIMD<UInt16>.laneCount).map { UInt16(truncatingIfNeeded: $0 &* 37 &+ 11) }
        )
        let genericShorts = quarterVectorOps(shorts)
        let concreteShorts = ContiguousArray<UInt16>(capacity: SIMD<UInt16>.laneCount) { output in
            SIMD<UInt16>.append(SIMD<UInt16>.loadQuarter(from: shorts.span), to: &output)
        }

        #expect(genericShorts == Array(concreteShorts))
        #expect(genericShorts == Array(shorts.prefix(SIMD<UInt16>.laneCount / 4)))

        let bytes = ContiguousArray(
            (0..<SIMD<Int8>.laneCount).map { Int8(truncatingIfNeeded: $0 &* 37 &- 90) }
        )
        let genericBytes = quarterVectorOps(bytes)
        let concreteBytes = ContiguousArray<Int8>(capacity: SIMD<Int8>.laneCount) { output in
            SIMD<Int8>.append(SIMD<Int8>.loadQuarter(from: bytes.span), to: &output)
        }

        #expect(genericBytes == Array(concreteBytes))
        #expect(genericBytes == Array(bytes.prefix(SIMD<Int8>.laneCount / 4)))
    }

    @Test(
        "Ops of SIMDEighthVectorElement called through a generic lane type match the concrete ones"
    )
    func eighthVectorOpsMatchConcreteOnes() {
        let bytes = ContiguousArray(
            (0..<SIMD<UInt8>.laneCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        )
        let genericBytes = eighthVectorOps(bytes)
        let concreteEighth = ContiguousArray<UInt8>(capacity: SIMD<UInt8>.laneCount) { output in
            SIMD<UInt8>.append(SIMD<UInt8>.loadEighth(from: bytes.span), to: &output)
        }
        let concreteQuarter = ContiguousArray<UInt8>(capacity: SIMD<UInt8>.laneCount) { output in
            SIMD<UInt8>.append(SIMD<UInt8>.loadQuarter(from: bytes.span), to: &output)
        }

        #expect(genericBytes.eighth == Array(concreteEighth))
        #expect(genericBytes.quarter == Array(concreteQuarter))
        #expect(genericBytes.eighth == Array(bytes.prefix(SIMD<UInt8>.laneCount / 8)))
        #expect(genericBytes.quarter == Array(bytes.prefix(SIMD<UInt8>.laneCount / 4)))

        let signedBytes = ContiguousArray(
            (0..<SIMD<Int8>.laneCount).map { Int8(truncatingIfNeeded: $0 &* 37 &- 90) }
        )
        let genericSignedBytes = eighthVectorOps(signedBytes)
        let signedEighth = ContiguousArray<Int8>(capacity: SIMD<Int8>.laneCount) { output in
            SIMD<Int8>.append(SIMD<Int8>.loadEighth(from: signedBytes.span), to: &output)
        }
        let signedQuarter = ContiguousArray<Int8>(capacity: SIMD<Int8>.laneCount) { output in
            SIMD<Int8>.append(SIMD<Int8>.loadQuarter(from: signedBytes.span), to: &output)
        }

        #expect(genericSignedBytes.eighth == Array(signedEighth))
        #expect(genericSignedBytes.quarter == Array(signedQuarter))
        #expect(genericSignedBytes.eighth == Array(signedBytes.prefix(SIMD<Int8>.laneCount / 8)))
        #expect(genericSignedBytes.quarter == Array(signedBytes.prefix(SIMD<Int8>.laneCount / 4)))
    }
}
