import Testing
import Vectorization

@Suite("Narrow masks")
struct NarrowMaskTests {
    func pattern(lanes: Int) -> [UInt8] {
        (0..<lanes).map { $0 % 3 == 0 || $0 == lanes - 1 ? 1 : 0 }
    }

    func mask<Element: SIMDElement>(
        _ type: Element.Type,
        pattern: [UInt8]
    ) -> Element.Mask where Element.Lane: FixedWidthInteger {
        let lanes = ContiguousArray(pattern.map { Element.Lane($0) })
        return Element.notEqualTo(Element.load(from: lanes.span), Element.zero())
    }

    func lanes<Lane: FixedWidthInteger, Raw: BitwiseCopyable>(
        _ raw: Raw,
        as type: Lane.Type,
        count: Int
    ) -> [Lane] {
        withUnsafeBytes(of: raw) { bytes in
            (0..<count).map {
                unsafe bytes.loadUnaligned(
                    fromByteOffset: $0 * MemoryLayout<Lane>.size,
                    as: Lane.self
                )
            }
        }
    }

    func expected<Lane: FixedWidthInteger & SignedInteger>(
        _ pattern: ArraySlice<UInt8>,
        as type: Lane.Type
    ) -> [Lane] {
        pattern.map { $0 == 0 ? 0 : -1 }
    }

    @Test("Halves split a mask and combine into it")
    func splitsAndCombines() {
        typealias H = SIMDUInt16
        let lanes = H.laneCount
        let pattern = pattern(lanes: lanes)
        let source = mask(H.self, pattern: pattern)
        let lower = H.lowerHalf(source)
        let upper = H.upperHalf(source)

        #expect(
            self.lanes(lower.raw, as: Int16.self, count: lanes / 2)
                == expected(pattern.prefix(lanes / 2), as: Int16.self)
        )
        #expect(
            self.lanes(upper.raw, as: Int16.self, count: lanes / 2)
                == expected(pattern.suffix(lanes / 2), as: Int16.self)
        )
        #expect(
            self.lanes(H.combining(upper, lower).raw, as: Int16.self, count: lanes)
                == expected(pattern[...], as: Int16.self)
        )
        #expect(
            self.lanes(H.combining(lower, upper).raw, as: Int16.self, count: lanes)
                == expected(
                    (pattern.suffix(lanes / 2) + pattern.prefix(lanes / 2))[...],
                    as: Int16.self
                )
        )
    }

    @Test("A half mask of 64-bit lanes splits and combines, however many lanes it has")
    func splitsAndCombinesWideLanes() {
        typealias H = SIMDUInt64
        let lanes = H.laneCount
        let pattern = pattern(lanes: lanes)
        let source = mask(H.self, pattern: pattern)
        let lower = H.lowerHalf(source)
        let upper = H.upperHalf(source)

        #expect(
            self.lanes(lower.raw, as: Int64.self, count: lanes / 2)
                == expected(pattern.prefix(lanes / 2), as: Int64.self)
        )
        #expect(
            self.lanes(upper.raw, as: Int64.self, count: lanes / 2)
                == expected(pattern.suffix(lanes / 2), as: Int64.self)
        )
        #expect(
            self.lanes(H.combining(upper, lower).raw, as: Int64.self, count: lanes)
                == expected(pattern[...], as: Int64.self)
        )
    }

    @Test("A mask narrows to a narrow mask and widens back, whatever the lane types are")
    func narrowsAndWidens() {
        let bytes = pattern(lanes: SIMDUInt16.laneCount)
        let words = mask(SIMDUInt16.self, pattern: bytes)
        let half = SIMDUInt8.halfMask(narrowing: words)
        #expect(
            lanes(half.raw, as: Int8.self, count: bytes.count)
                == expected(bytes[...], as: Int8.self)
        )
        #expect(
            lanes(SIMDUInt16.mask(widening: half).raw, as: Int16.self, count: bytes.count)
                == expected(bytes[...], as: Int16.self)
        )
        #expect(
            lanes(SIMDInt16.mask(widening: half).raw, as: Int16.self, count: bytes.count)
                == expected(bytes[...], as: Int16.self)
        )

        let doubles = pattern(lanes: SIMDUInt32.laneCount)
        let quarter = SIMDUInt8.quarterMask(narrowing: mask(SIMDUInt32.self, pattern: doubles))
        #expect(
            lanes(SIMDFloat.mask(widening: quarter).raw, as: Int32.self, count: doubles.count)
                == expected(doubles[...], as: Int32.self)
        )

        let quads = pattern(lanes: SIMDUInt64.laneCount)
        let eighth = SIMDUInt8.eighthMask(narrowing: mask(SIMDUInt64.self, pattern: quads))
        #expect(
            lanes(SIMDDouble.mask(widening: eighth).raw, as: Int64.self, count: quads.count)
                == expected(quads[...], as: Int64.self)
        )
    }

    @Test("A narrow mask converts to and from its SIMD type")
    func convertsToSIMD() {
        typealias H = SIMDUInt16
        let lanes = H.laneCount / 2
        let pattern = pattern(lanes: H.laneCount)
        let half = H.lowerHalf(mask(H.self, pattern: pattern))
        let simd = half.simd

        #expect(
            self.lanes(simd, as: Int16.self, count: lanes)
                == expected(pattern.prefix(lanes), as: Int16.self)
        )
        #expect(
            self.lanes(H.HalfMask(simd).raw, as: Int16.self, count: lanes)
                == expected(pattern.prefix(lanes), as: Int16.self)
        )
    }
}
