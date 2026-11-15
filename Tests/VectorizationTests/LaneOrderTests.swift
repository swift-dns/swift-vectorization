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

    func verifyMultiplyingHigh<H: SIMDIntegerElement>(_ type: H.Type)
    where H.Lane: FixedWidthInteger {
        let a = Self.pattern(H.Lane.self, count: H.laneCount, seed: 0x9E37_79B9_7F4A_7C15)
        let b = Self.pattern(H.Lane.self, count: H.laneCount, seed: 0xC2B2_AE3D_27D4_EB4F)
        let high = H.multiplyingHigh(load(H.self, a), load(H.self, b))

        #expect(lanes(H.self, high) == zip(a, b).map { $0.multipliedFullWidth(by: $1).high })
    }

    func verifyOddEven<H: SIMDElement>(_ type: H.Type, _ lane: (Int) -> H.Lane)
    where H.Lane: Equatable {
        let a = (0..<H.laneCount).map { lane($0 + 1) }
        let b = (0..<H.laneCount).map { lane($0 + 101) }

        #expect(
            lanes(H.self, H.oddEven(load(H.self, a), load(H.self, b)))
                == a.indices.map { $0 % 2 == 1 ? a[$0] : b[$0] }
        )
    }

    func verifyWidening<Source: SIMDElement, Result: SIMDElement>(
        _ source: Source.Type,
        _ result: Result.Type,
        even: (Source.Vector) -> Result.Vector,
        odd: (Source.Vector) -> Result.Vector,
        _ lane: (Int) -> Source.Lane,
        converted: (Source.Lane) -> Result.Lane
    ) where Result.Lane: Equatable {
        let a = (0..<Source.laneCount).map(lane)
        let vector = load(Source.self, a)

        #expect(
            lanes(Result.self, even(vector)) == (0..<Result.laneCount).map { converted(a[2 * $0]) }
        )
        #expect(
            lanes(Result.self, odd(vector))
                == (0..<Result.laneCount).map { converted(a[2 * $0 + 1]) }
        )
    }

    func verifyMultiplying<Source: SIMDElement, Result: SIMDElement>(
        _ source: Source.Type,
        _ result: Result.Type,
        even: (Source.Vector, Source.Vector) -> Result.Vector,
        odd: (Source.Vector, Source.Vector) -> Result.Vector
    ) where Source.Lane: FixedWidthInteger, Result.Lane: FixedWidthInteger {
        let a = Self.pattern(Source.Lane.self, count: Source.laneCount, seed: 0x9E37_79B9_7F4A_7C15)
        let b = Self.pattern(Source.Lane.self, count: Source.laneCount, seed: 0xC2B2_AE3D_27D4_EB4F)
        let (va, vb) = (load(Source.self, a), load(Source.self, b))
        let products = { (parity: Int) in
            (0..<Result.laneCount).map {
                Result.Lane(a[2 * $0 + parity]) * Result.Lane(b[2 * $0 + parity])
            }
        }

        #expect(lanes(Result.self, even(va, vb)) == products(0))
        #expect(lanes(Result.self, odd(va, vb)) == products(1))
    }

    @Test("multiplyingHigh keeps the upper half of the product of each lane")
    func multiplyingHighKeepsUpperHalves() {
        verifyMultiplyingHigh(SIMDUInt8.self)
        verifyMultiplyingHigh(SIMDInt8.self)
        verifyMultiplyingHigh(SIMDUInt16.self)
        verifyMultiplyingHigh(SIMDInt16.self)
        verifyMultiplyingHigh(SIMDUInt32.self)
        verifyMultiplyingHigh(SIMDInt32.self)
    }

    @Test("oddEven takes the odd lanes of the first vector and the even lanes of the second")
    func oddEvenPicksLanesByIndex() {
        verifyOddEven(SIMDUInt8.self) { UInt8(truncatingIfNeeded: $0) }
        verifyOddEven(SIMDInt8.self) { Int8(truncatingIfNeeded: $0) }
        verifyOddEven(SIMDUInt16.self) { UInt16($0) }
        verifyOddEven(SIMDInt16.self) { Int16($0) }
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        verifyOddEven(SIMDFloat16.self) { Float16($0) }
        #endif
    }

    @Test("Widening the even or the odd lanes takes the lanes of that index")
    func wideningEvenOrOddPicksLanesByIndex() {
        let bytes = { (index: Int) in UInt8(truncatingIfNeeded: index &* 37 &+ 200) }
        let words = { (index: Int) in UInt16(truncatingIfNeeded: index &* 9973 &+ 40000) }
        let doublewords = { (index: Int) in UInt32(truncatingIfNeeded: index) &* 0x9E37_79B9 }

        verifyWidening(
            SIMDUInt8.self,
            SIMDUInt16.self,
            even: SIMDUInt16.vector(wideningEven:),
            odd: SIMDUInt16.vector(wideningOdd:),
            bytes,
            converted: UInt16.init
        )
        verifyWidening(
            SIMDUInt8.self,
            SIMDInt16.self,
            even: SIMDInt16.vector(wideningEven:),
            odd: SIMDInt16.vector(wideningOdd:),
            bytes,
            converted: Int16.init
        )
        verifyWidening(
            SIMDInt8.self,
            SIMDInt16.self,
            even: SIMDInt16.vector(wideningEven:),
            odd: SIMDInt16.vector(wideningOdd:),
            { Int8(truncatingIfNeeded: bytes($0)) },
            converted: Int16.init
        )
        verifyWidening(
            SIMDUInt16.self,
            SIMDUInt32.self,
            even: SIMDUInt32.vector(wideningEven:),
            odd: SIMDUInt32.vector(wideningOdd:),
            words,
            converted: UInt32.init
        )
        verifyWidening(
            SIMDUInt16.self,
            SIMDInt32.self,
            even: SIMDInt32.vector(wideningEven:),
            odd: SIMDInt32.vector(wideningOdd:),
            words,
            converted: Int32.init
        )
        verifyWidening(
            SIMDInt16.self,
            SIMDInt32.self,
            even: SIMDInt32.vector(wideningEven:),
            odd: SIMDInt32.vector(wideningOdd:),
            { Int16(truncatingIfNeeded: words($0)) },
            converted: Int32.init
        )
        verifyWidening(
            SIMDUInt32.self,
            SIMDUInt64.self,
            even: SIMDUInt64.vector(wideningEven:),
            odd: SIMDUInt64.vector(wideningOdd:),
            doublewords,
            converted: UInt64.init
        )
        verifyWidening(
            SIMDUInt32.self,
            SIMDInt64.self,
            even: SIMDInt64.vector(wideningEven:),
            odd: SIMDInt64.vector(wideningOdd:),
            doublewords,
            converted: Int64.init
        )
        verifyWidening(
            SIMDInt32.self,
            SIMDInt64.self,
            even: SIMDInt64.vector(wideningEven:),
            odd: SIMDInt64.vector(wideningOdd:),
            { Int32(truncatingIfNeeded: doublewords($0)) },
            converted: Int64.init
        )
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        verifyWidening(
            SIMDFloat16.self,
            SIMDFloat.self,
            even: SIMDFloat.vector(wideningEven:),
            odd: SIMDFloat.vector(wideningOdd:),
            { Float16($0) * 1.5 - 7 },
            converted: Float.init
        )
        #endif
    }

    @Test("Multiplying the even or the odd lanes multiplies the lanes of that index")
    func multiplyingEvenOrOddPicksLanesByIndex() {
        verifyMultiplying(
            SIMDUInt8.self,
            SIMDUInt16.self,
            even: SIMDUInt16.multiplyingEven,
            odd: SIMDUInt16.multiplyingOdd
        )
        verifyMultiplying(
            SIMDInt8.self,
            SIMDInt16.self,
            even: SIMDInt16.multiplyingEven,
            odd: SIMDInt16.multiplyingOdd
        )
        verifyMultiplying(
            SIMDUInt16.self,
            SIMDUInt32.self,
            even: SIMDUInt32.multiplyingEven,
            odd: SIMDUInt32.multiplyingOdd
        )
        verifyMultiplying(
            SIMDInt16.self,
            SIMDInt32.self,
            even: SIMDInt32.multiplyingEven,
            odd: SIMDInt32.multiplyingOdd
        )
        verifyMultiplying(
            SIMDUInt32.self,
            SIMDUInt64.self,
            even: SIMDUInt64.multiplyingEven,
            odd: SIMDUInt64.multiplyingOdd
        )
        verifyMultiplying(
            SIMDInt32.self,
            SIMDInt64.self,
            even: SIMDInt64.multiplyingEven,
            odd: SIMDInt64.multiplyingOdd
        )
    }

    @Test("Widening the even or the odd bfloat16 lanes takes the lanes of that index")
    func wideningEvenOrOddBFloat16PicksLanesByIndex() {
        let a = (0..<SIMDBFloat16.laneCount).map { BFloat16(Float($0) * 1.5 - 7) }
        let vector = load(a)
        let widened = { (parity: Int) in (0..<SIMDFloat.laneCount).map { Float(a[2 * $0 + parity]) }
        }

        #expect(lanes(SIMDFloat.self, SIMDFloat.vector(wideningEven: vector)) == widened(0))
        #expect(lanes(SIMDFloat.self, SIMDFloat.vector(wideningOdd: vector)) == widened(1))
    }

    @Test("Multiply-adding the even or the odd bfloat16 lanes takes the lanes of that index")
    func multiplyAddingEvenOrOddBFloat16PicksLanesByIndex() {
        let a = (0..<SIMDBFloat16.laneCount).map { BFloat16(Float($0) - 3) }
        let b = (0..<SIMDBFloat16.laneCount).map { BFloat16(Float($0) * 0.5 + 1) }
        let c = (0..<SIMDFloat.laneCount).map { Float($0) * 100 }
        let (va, vb) = (load(a), load(b))
        let vc = load(SIMDFloat.self, c)
        let sums = { (parity: Int) in
            c.indices.map { Float(a[2 * $0 + parity]) * Float(b[2 * $0 + parity]) + c[$0] }
        }

        #expect(lanes(SIMDFloat.self, SIMDFloat.multiplyAddingEven(va, vb, vc)) == sums(0))
        #expect(lanes(SIMDFloat.self, SIMDFloat.multiplyAddingOdd(va, vb, vc)) == sums(1))
    }

    @Test("Converting two float vectors to bfloat16 keeps the lanes of the first vector first")
    func convertingFloatPairToBFloat16KeepsLaneOrder() {
        let a = (0..<SIMDFloat.laneCount).map { Float($0) * 1.25 + 0.5 }
        let b = (0..<SIMDFloat.laneCount).map { -Float($0) * 3 - 1.0 / 3 }
        let converted = SIMDBFloat16.vector(
            converting: load(SIMDFloat.self, a),
            load(SIMDFloat.self, b)
        )

        #expect(lanes(converted) == (a + b).map(BFloat16.init))
    }
}

private func load<H: SIMDElement>(_ type: H.Type, _ lanes: [H.Lane]) -> H.Vector {
    H.load(from: ContiguousArray(lanes).span)
}

private func lanes<H: SIMDElement>(_ type: H.Type, _ vector: H.Vector) -> [H.Lane] {
    let output = ContiguousArray<H.Lane>(capacity: H.laneCount) { output in
        H.append(vector, to: &output)
    }
    return Array(output)
}

private func load(_ lanes: [BFloat16]) -> SIMDBFloat16.Vector {
    SIMDBFloat16.load(from: ContiguousArray(lanes).span)
}

private func lanes(_ vector: SIMDBFloat16.Vector) -> [BFloat16] {
    let output = ContiguousArray<BFloat16>(capacity: SIMDBFloat16.laneCount) { output in
        SIMDBFloat16.append(vector, to: &output)
    }
    return Array(output)
}
