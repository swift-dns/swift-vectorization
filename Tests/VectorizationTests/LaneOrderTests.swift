import Testing
import Vectorization

@Suite("Lane order")
struct LaneOrderTests {
    static func pattern<Lane: FixedWidthInteger>(
        _ type: Lane.Type,
        count: Int,
        seed: UInt64
    ) -> [Lane] {
        (0..<count).map { Lane(truncatingIfNeeded: ((UInt64($0) &+ 1) &* seed) >> 17) }
    }

    func verifyMultiplyingHigh<Lane: SIMDIntegerElement & FixedWidthInteger>(_ type: Lane.Type) {
        typealias H = SIMD<Lane>

        let a = Self.pattern(Lane.self, count: H.laneCount, seed: 0x9E37_79B9_7F4A_7C15)
        let b = Self.pattern(Lane.self, count: H.laneCount, seed: 0xC2B2_AE3D_27D4_EB4F)
        let high = H.multiplyingHigh(load(a), load(b))

        #expect(lanes(high) == zip(a, b).map { $0.multipliedFullWidth(by: $1).high })
    }

    func verifyOddEven<Lane: SIMDNumericElement & Equatable>(
        _ type: Lane.Type,
        _ lane: (Int) -> Lane
    ) {
        typealias H = SIMD<Lane>

        let a = (0..<H.laneCount).map { lane($0 + 1) }
        let b = (0..<H.laneCount).map { lane($0 + 101) }

        #expect(
            lanes(H.oddEven(load(a), load(b))) == a.indices.map { $0 % 2 == 1 ? a[$0] : b[$0] }
        )
    }

    func verifyWidening<Source: SIMDElement, Result: SIMDElement & Equatable>(
        _ source: Source.Type,
        _ result: Result.Type,
        even: (SIMD<Source>) -> SIMD<Result>,
        odd: (SIMD<Source>) -> SIMD<Result>,
        _ lane: (Int) -> Source,
        converted: (Source) -> Result
    ) {
        let a = (0..<SIMD<Source>.laneCount).map(lane)
        let vector = load(a)

        #expect(
            lanes(even(vector)) == (0..<SIMD<Result>.laneCount).map { converted(a[2 * $0]) }
        )
        #expect(
            lanes(odd(vector)) == (0..<SIMD<Result>.laneCount).map { converted(a[2 * $0 + 1]) }
        )
    }

    func verifyMultiplying<
        Source: SIMDElement & FixedWidthInteger,
        Result: SIMDElement & FixedWidthInteger
    >(
        _ source: Source.Type,
        _ result: Result.Type,
        even: (SIMD<Source>, SIMD<Source>) -> SIMD<Result>,
        odd: (SIMD<Source>, SIMD<Source>) -> SIMD<Result>
    ) {
        let a = Self.pattern(
            Source.self,
            count: SIMD<Source>.laneCount,
            seed: 0x9E37_79B9_7F4A_7C15
        )
        let b = Self.pattern(
            Source.self,
            count: SIMD<Source>.laneCount,
            seed: 0xC2B2_AE3D_27D4_EB4F
        )
        let (va, vb) = (load(a), load(b))
        let products = { (parity: Int) in
            (0..<SIMD<Result>.laneCount).map {
                Result(a[2 * $0 + parity]) * Result(b[2 * $0 + parity])
            }
        }

        #expect(lanes(even(va, vb)) == products(0))
        #expect(lanes(odd(va, vb)) == products(1))
    }

    @Test("multiplyingHigh keeps the upper half of the product of each lane")
    func multiplyingHighKeepsUpperHalves() {
        verifyMultiplyingHigh(UInt8.self)
        verifyMultiplyingHigh(Int8.self)
        verifyMultiplyingHigh(UInt16.self)
        verifyMultiplyingHigh(Int16.self)
        verifyMultiplyingHigh(UInt32.self)
        verifyMultiplyingHigh(Int32.self)
    }

    @Test("oddEven takes the odd lanes of the first vector and the even lanes of the second")
    func oddEvenPicksLanesByIndex() {
        verifyOddEven(UInt8.self) { UInt8(truncatingIfNeeded: $0) }
        verifyOddEven(Int8.self) { Int8(truncatingIfNeeded: $0) }
        verifyOddEven(UInt16.self) { UInt16($0) }
        verifyOddEven(Int16.self) { Int16($0) }
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        verifyOddEven(Float16.self) { Float16($0) }
        #endif
    }

    @Test("Widening the even or the odd lanes takes the lanes of that index")
    func wideningEvenOrOddPicksLanesByIndex() {
        let bytes = { (index: Int) in UInt8(truncatingIfNeeded: index &* 37 &+ 200) }
        let words = { (index: Int) in UInt16(truncatingIfNeeded: index &* 9973 &+ 40000) }
        let doublewords = { (index: Int) in UInt32(truncatingIfNeeded: index) &* 0x9E37_79B9 }

        verifyWidening(
            UInt8.self,
            UInt16.self,
            even: SIMD<UInt16>.vector(wideningEven:),
            odd: SIMD<UInt16>.vector(wideningOdd:),
            bytes,
            converted: UInt16.init
        )
        verifyWidening(
            UInt8.self,
            Int16.self,
            even: SIMD<Int16>.vector(wideningEven:),
            odd: SIMD<Int16>.vector(wideningOdd:),
            bytes,
            converted: Int16.init
        )
        verifyWidening(
            Int8.self,
            Int16.self,
            even: SIMD<Int16>.vector(wideningEven:),
            odd: SIMD<Int16>.vector(wideningOdd:),
            { Int8(truncatingIfNeeded: bytes($0)) },
            converted: Int16.init
        )
        verifyWidening(
            UInt16.self,
            UInt32.self,
            even: SIMD<UInt32>.vector(wideningEven:),
            odd: SIMD<UInt32>.vector(wideningOdd:),
            words,
            converted: UInt32.init
        )
        verifyWidening(
            UInt16.self,
            Int32.self,
            even: SIMD<Int32>.vector(wideningEven:),
            odd: SIMD<Int32>.vector(wideningOdd:),
            words,
            converted: Int32.init
        )
        verifyWidening(
            Int16.self,
            Int32.self,
            even: SIMD<Int32>.vector(wideningEven:),
            odd: SIMD<Int32>.vector(wideningOdd:),
            { Int16(truncatingIfNeeded: words($0)) },
            converted: Int32.init
        )
        verifyWidening(
            UInt32.self,
            UInt64.self,
            even: SIMD<UInt64>.vector(wideningEven:),
            odd: SIMD<UInt64>.vector(wideningOdd:),
            doublewords,
            converted: UInt64.init
        )
        verifyWidening(
            UInt32.self,
            Int64.self,
            even: SIMD<Int64>.vector(wideningEven:),
            odd: SIMD<Int64>.vector(wideningOdd:),
            doublewords,
            converted: Int64.init
        )
        verifyWidening(
            Int32.self,
            Int64.self,
            even: SIMD<Int64>.vector(wideningEven:),
            odd: SIMD<Int64>.vector(wideningOdd:),
            { Int32(truncatingIfNeeded: doublewords($0)) },
            converted: Int64.init
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        verifyWidening(
            Float16.self,
            Float.self,
            even: SIMD<Float>.vector(wideningEven:),
            odd: SIMD<Float>.vector(wideningOdd:),
            { Float16($0) * 1.5 - 7 },
            converted: Float.init
        )
        #endif
    }

    @Test("Multiplying the even or the odd lanes multiplies the lanes of that index")
    func multiplyingEvenOrOddPicksLanesByIndex() {
        verifyMultiplying(
            UInt8.self,
            UInt16.self,
            even: SIMD<UInt16>.multiplyingEven,
            odd: SIMD<UInt16>.multiplyingOdd
        )
        verifyMultiplying(
            Int8.self,
            Int16.self,
            even: SIMD<Int16>.multiplyingEven,
            odd: SIMD<Int16>.multiplyingOdd
        )
        verifyMultiplying(
            UInt16.self,
            UInt32.self,
            even: SIMD<UInt32>.multiplyingEven,
            odd: SIMD<UInt32>.multiplyingOdd
        )
        verifyMultiplying(
            Int16.self,
            Int32.self,
            even: SIMD<Int32>.multiplyingEven,
            odd: SIMD<Int32>.multiplyingOdd
        )
        verifyMultiplying(
            UInt32.self,
            UInt64.self,
            even: SIMD<UInt64>.multiplyingEven,
            odd: SIMD<UInt64>.multiplyingOdd
        )
        verifyMultiplying(
            Int32.self,
            Int64.self,
            even: SIMD<Int64>.multiplyingEven,
            odd: SIMD<Int64>.multiplyingOdd
        )
    }

    @Test("Widening the even or the odd bfloat16 lanes takes the lanes of that index")
    func wideningEvenOrOddBFloat16PicksLanesByIndex() {
        let a = (0..<SIMD<BFloat16>.laneCount).map { BFloat16(Float($0) * 1.5 - 7) }
        let vector = load(a)
        let widened = { (parity: Int) in
            (0..<SIMD<Float>.laneCount).map { Float(a[2 * $0 + parity]) }
        }

        #expect(lanes(SIMD<Float>.vector(wideningEven: vector)) == widened(0))
        #expect(lanes(SIMD<Float>.vector(wideningOdd: vector)) == widened(1))
    }

    @Test("Multiply-adding the even or the odd bfloat16 lanes takes the lanes of that index")
    func multiplyAddingEvenOrOddBFloat16PicksLanesByIndex() {
        let a = (0..<SIMD<BFloat16>.laneCount).map { BFloat16(Float($0) - 3) }
        let b = (0..<SIMD<BFloat16>.laneCount).map { BFloat16(Float($0) * 0.5 + 1) }
        let c = (0..<SIMD<Float>.laneCount).map { Float($0) * 100 }
        let (va, vb) = (load(a), load(b))
        let vc = load(c)
        let sums = { (parity: Int) in
            c.indices.map { Float(a[2 * $0 + parity]) * Float(b[2 * $0 + parity]) + c[$0] }
        }

        #expect(lanes(SIMD<Float>.multiplyAddingEven(va, vb, vc)) == sums(0))
        #expect(lanes(SIMD<Float>.multiplyAddingOdd(va, vb, vc)) == sums(1))
    }

    @Test("Converting two float vectors to bfloat16 keeps the lanes of the first vector first")
    func convertingFloatPairToBFloat16KeepsLaneOrder() {
        let a = (0..<SIMD<Float>.laneCount).map { Float($0) * 1.25 + 0.5 }
        let b = (0..<SIMD<Float>.laneCount).map { -Float($0) * 3 - 1.0 / 3 }
        let converted = SIMD<BFloat16>.vector(
            converting: load(a),
            load(b)
        )

        #expect(lanes(converted) == (a + b).map(BFloat16.init))
    }
}

private func load<Lane: SIMDElement>(_ lanes: [Lane]) -> SIMD<Lane> {
    SIMD<Lane>.load(from: ContiguousArray(lanes).span)
}

private func lanes<Lane: SIMDElement>(_ vector: SIMD<Lane>) -> [Lane] {
    let output = ContiguousArray<Lane>(capacity: SIMD<Lane>.laneCount) { output in
        SIMD<Lane>.append(vector, to: &output)
    }
    return Array(output)
}
