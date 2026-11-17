import Testing
import Vectorization

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

@Suite("Ops")
struct OpsTests {
    @Test("A vector survives a store after a load")
    func loadStoreRoundTrip() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = (0..<lanes).map { UInt8($0 &* 3) }
        var output = [UInt8](repeating: 0, count: lanes)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                unsafe H.store(H.load(from: source.baseAddress!), to: destination.baseAddress!)
            }
        }

        #expect(output == input)
    }

    @Test("Arithmetic matches the scalar result")
    func arithmetic() {
        typealias H = SIMD<Int32>
        let lanes = H.laneCount
        let a = (0..<lanes).map { Int32($0) - 4 }
        let b = (0..<lanes).map { Int32($0) * 3 }

        var sum = [Int32](repeating: 0, count: lanes)
        var product = [Int32](repeating: 0, count: lanes)
        var smallest = [Int32](repeating: 0, count: lanes)

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let va = unsafe H.load(from: pa.baseAddress!)
                let vb = unsafe H.load(from: pb.baseAddress!)
                sum.withUnsafeMutableBufferPointer {
                    unsafe H.store(H.adding(va, vb), to: $0.baseAddress!)
                }
                product.withUnsafeMutableBufferPointer {
                    unsafe H.store(H.multiplying(va, vb), to: $0.baseAddress!)
                }
                smallest.withUnsafeMutableBufferPointer {
                    unsafe H.store(H.minimum(va, vb), to: $0.baseAddress!)
                }
            }
        }

        #expect(sum == zip(a, b).map(&+))
        #expect(product == zip(a, b).map(&*))
        #expect(smallest == zip(a, b).map(Swift.min))
    }

    @Test("Multiply-adding the low 52 bits of a product keeps what is below bit 52")
    func multiplyAddingLow52Bits() {
        typealias H = SIMD<UInt64>
        let lanes = H.laneCount
        let limit: UInt64 = 1 << 52
        let cases: [(a: UInt64, b: UInt64, c: UInt64)] = [
            (limit - 1, limit - 1, 0),
            (limit - 1, limit - 1, .max),
            (limit - 1, 1, 7),
            (0, limit - 1, 3),
            (1 << 32, 1 << 32, 1),
            ((1 << 51) + 12345, limit - 7, 1 << 63),
            (0x1_2345_6789, 0xF_EDCB_A987_6543, 0xFFFF_FFFF),
            (1 << 26, 1 << 26, 0),
        ]

        for offset in cases.indices {
            let chosen = (0..<lanes).map { cases[($0 + offset) % cases.count] }
            let a = ContiguousArray(chosen.map(\.a))
            let b = ContiguousArray(chosen.map(\.b))
            let c = ContiguousArray(chosen.map(\.c))
            var output = ContiguousArray<UInt64>(repeating: 0, count: lanes)

            var destination = output.mutableSpan
            H.store(
                H.multiplyAddingLow52Bits(
                    H.load(from: a.span),
                    H.load(from: b.span),
                    H.load(from: c.span)
                ),
                to: &destination
            )

            let expected = chosen.map { (($0.a &* $0.b) & (limit - 1)) &+ $0.c }
            #expect(Array(output) == expected)
        }
    }

    @Test("Multiply-adding the high 52 bits of a product keeps bits 52 to 103, past the carry")
    func multiplyAddingHigh52Bits() {
        typealias H = SIMD<UInt64>
        let lanes = H.laneCount
        let limit: UInt64 = 1 << 52
        let cases: [(a: UInt64, b: UInt64, c: UInt64)] = [
            (limit - 1, limit - 1, 0),
            (limit - 1, limit - 1, .max),
            (limit - 1, 1, 7),
            (0, limit - 1, 3),
            (1 << 32, 1 << 32, 1),
            (1 << 51, 1 << 51, 0),
            ((1 << 51) + 12345, limit - 7, 1 << 63),
            (0x1_2345_6789, 0xF_EDCB_A987_6543, 0xFFFF_FFFF),
            (0xF_FFFF_FFFF_FFFF, 0xF_0000_0001, 0),
            (0x0_FFFF_FFFF, 0xF_FFFF_FFFF_FFFF, 0),
        ]

        for offset in cases.indices {
            let chosen = (0..<lanes).map { cases[($0 + offset) % cases.count] }
            let a = ContiguousArray(chosen.map(\.a))
            let b = ContiguousArray(chosen.map(\.b))
            let c = ContiguousArray(chosen.map(\.c))
            var output = ContiguousArray<UInt64>(repeating: 0, count: lanes)

            var destination = output.mutableSpan
            H.store(
                H.multiplyAddingHigh52Bits(
                    H.load(from: a.span),
                    H.load(from: b.span),
                    H.load(from: c.span)
                ),
                to: &destination
            )

            let expected = chosen.map { lane in
                let product = lane.a.multipliedFullWidth(by: lane.b)
                return ((product.low >> 52) | (product.high << 12)) &+ lane.c
            }
            #expect(Array(output) == expected)
        }
    }

    @Test("Shifts and bitwise ops match the scalar result")
    func bitwise() {
        typealias H = SIMD<UInt32>
        let lanes = H.laneCount
        let a = (0..<lanes).map { UInt32(truncatingIfNeeded: $0) &* 2_654_435_761 }

        var shifted = [UInt32](repeating: 0, count: lanes)
        var masked = [UInt32](repeating: 0, count: lanes)

        a.withUnsafeBufferPointer { pa in
            let va = unsafe H.load(from: pa.baseAddress!)
            let mask = H.repeating(0xFF)
            shifted.withUnsafeMutableBufferPointer {
                unsafe H.store(H.shiftedRight(va, by: 8), to: $0.baseAddress!)
            }
            masked.withUnsafeMutableBufferPointer {
                unsafe H.store(H.bitwiseAnd(va, mask), to: $0.baseAddress!)
            }
        }

        #expect(shifted == a.map { $0 >> 8 })
        #expect(masked == a.map { $0 & 0xFF })
    }

    @Test("An and-xor combines three vectors lane by lane")
    func bitwiseAndXor() {
        func check<Lane: SIMDIntegerElement & FixedWidthInteger>(_ type: Lane.Type) {
            typealias H = SIMD<Lane>
            let lanes = H.laneCount
            let a = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let b = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 91 &+ 5) })
            let c = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 53 &+ 29) })
            var output = ContiguousArray<Lane>(repeating: 0, count: lanes)

            var destination = output.mutableSpan
            H.store(
                H.bitwiseAndXor(H.load(from: a.span), H.load(from: b.span), H.load(from: c.span)),
                to: &destination
            )

            #expect(Array(output) == (0..<lanes).map { a[$0] & (b[$0] ^ c[$0]) })
        }

        check(UInt32.self)
        check(Int8.self)
    }

    @Test("A masked bitwise op zeroes the lanes the mask does not select")
    func maskedBitwise() {
        func check<Lane: SIMDIntegerElement & FixedWidthInteger>(_ type: Lane.Type) {
            typealias H = SIMD<Lane>
            let lanes = H.laneCount
            let selected = lanes / 2
            let a = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let b = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 91 &+ 5) })
            let mask = H.firstLanes(count: selected)
            let operations: [(vector: H, scalar: (Lane, Lane) -> Lane)] = [
                (
                    H.bitwiseAnd(H.load(from: a.span), H.load(from: b.span), where: mask),
                    { $0 & $1 }
                ),
                (H.bitwiseOr(H.load(from: a.span), H.load(from: b.span), where: mask), { $0 | $1 }),
                (
                    H.bitwiseXor(H.load(from: a.span), H.load(from: b.span), where: mask),
                    { $0 ^ $1 }
                ),
            ]

            for operation in operations {
                var output = ContiguousArray<Lane>(repeating: 1, count: lanes)
                var destination = output.mutableSpan
                H.store(operation.vector, to: &destination)
                let expected = (0..<lanes).map { lane in
                    lane < selected ? operation.scalar(a[lane], b[lane]) : 0
                }
                #expect(Array(output) == expected)
            }
        }

        check(UInt16.self)
        check(Int64.self)
    }

    @Test("A masked bitwise op takes the lanes the mask does not select from otherwise")
    func maskedBitwiseOtherwise() {
        func check<Lane: SIMDIntegerElement & FixedWidthInteger>(_ type: Lane.Type) {
            typealias H = SIMD<Lane>
            let lanes = H.laneCount
            let selected = lanes / 2
            let a = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let b = ContiguousArray((0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 91 &+ 5) })
            let other = ContiguousArray(
                (0..<lanes).map { Lane(truncatingIfNeeded: $0 &* 53 &+ 29) }
            )
            let mask = H.firstLanes(count: selected)
            let (va, vb, vo) = (
                H.load(from: a.span), H.load(from: b.span), H.load(from: other.span)
            )
            let operations: [(vector: H, scalar: (Lane, Lane) -> Lane)] = [
                (H.bitwiseAnd(va, vb, where: mask, otherwise: vo), { $0 & $1 }),
                (H.bitwiseOr(va, vb, where: mask, otherwise: vo), { $0 | $1 }),
                (H.bitwiseXor(va, vb, where: mask, otherwise: vo), { $0 ^ $1 }),
            ]

            for operation in operations {
                var output = ContiguousArray<Lane>(repeating: 0, count: lanes)
                var destination = output.mutableSpan
                H.store(operation.vector, to: &destination)
                let expected = (0..<lanes).map { lane in
                    lane < selected ? operation.scalar(a[lane], b[lane]) : other[lane]
                }
                #expect(Array(output) == expected)
            }
        }

        check(UInt8.self)
        check(Int32.self)
    }

    @Test("Comparing produces a mask that selects")
    func compareAndSelect() {
        typealias H = SIMD<Float>
        let lanes = H.laneCount
        let a = (0..<lanes).map { Float($0) - 2 }

        var selected = [Float](repeating: 0, count: lanes)
        a.withUnsafeBufferPointer { pa in
            let va = unsafe H.load(from: pa.baseAddress!)
            let zero = H.zero()
            let isNegative = H.lessThan(va, zero)
            selected.withUnsafeMutableBufferPointer {
                unsafe H.store(H.selecting(isNegative, H.negated(va), va), to: $0.baseAddress!)
            }
        }

        #expect(selected == a.map(Swift.abs))
    }

    @Test("First lanes select every lane for any count of at least the lane count")
    func firstLanes() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        for count in [0, 1, lanes - 1, lanes, lanes + 1, 127, 128, 200, Int.max] {
            let mask = H.firstLanes(count: count)
            #expect(H.trueCount(mask) == min(count, lanes))
            #expect(H.firstTrueIndex(mask) == (count == 0 ? -1 : 0))
        }
    }

    @Test("Complex products of integer lanes wrap around as the scalar ones do")
    func integerComplexProductsWrap() {
        verifyWrappingComplexProducts(Int8.self)
        verifyWrappingComplexProducts(Int16.self)
        verifyWrappingComplexProducts(Int32.self)
        verifyWrappingComplexProducts(Int64.self)
    }

    @Test("Reductions match the scalar result")
    func reductions() {
        typealias H = SIMD<Int32>
        let lanes = H.laneCount
        let a = (0..<lanes).map { Int32($0) - 3 }

        var sum: Int32 = 0
        var largest: Int32 = 0
        a.withUnsafeBufferPointer { pa in
            let va = unsafe H.load(from: pa.baseAddress!)
            sum = H.sum(va)
            largest = H.largest(va)
        }

        #expect(sum == a.reduce(0, &+))
        #expect(largest == a.max())
    }

    @Test("Extrema or NaN are NaN when any lane is NaN, and the extrema otherwise")
    func extremaOrNaN() {
        typealias F = SIMD<Float>
        typealias D = SIMD<Double>
        let floats = ContiguousArray((0..<F.laneCount).map { Float($0 &* 3) - 4.5 })
        let doubles = ContiguousArray((0..<D.laneCount).map { Double($0 &* 3) - 4.5 })

        #expect(F.smallestOrNaN(F.load(from: floats.span)) == floats.min())
        #expect(F.largestOrNaN(F.load(from: floats.span)) == floats.max())
        #expect(D.smallestOrNaN(D.load(from: doubles.span)) == doubles.min())
        #expect(D.largestOrNaN(D.load(from: doubles.span)) == doubles.max())

        for nanLane in 0..<F.laneCount {
            var lanes = floats
            lanes[nanLane] = .nan
            let vector = F.load(from: lanes.span)
            #expect(F.smallestOrNaN(vector).isNaN)
            #expect(F.largestOrNaN(vector).isNaN)
        }
        for nanLane in 0..<D.laneCount {
            var lanes = doubles
            lanes[nanLane] = .nan
            let vector = D.load(from: lanes.span)
            #expect(D.smallestOrNaN(vector).isNaN)
            #expect(D.largestOrNaN(vector).isNaN)
        }

        #expect(F.smallestOrNaN(F.repeating(.nan)).isNaN)
        #expect(F.largestOrNaN(F.repeating(.nan)).isNaN)
        #expect(D.smallestOrNaN(D.repeating(.nan)).isNaN)
        #expect(D.largestOrNaN(D.repeating(.nan)).isNaN)
    }

    @Test("Extrema or NaN see past infinities and a NaN in the lane that would be the extremum")
    func extremaOrNaNWithInfinities() {
        typealias F = SIMD<Float>
        let lanes = F.laneCount

        for nanLane in 0..<lanes {
            var smallest = ContiguousArray(repeating: Float.infinity, count: lanes)
            var largest = ContiguousArray(repeating: -Float.infinity, count: lanes)
            smallest[nanLane] = .nan
            largest[nanLane] = .nan
            #expect(F.smallestOrNaN(F.load(from: smallest.span)).isNaN)
            #expect(F.largestOrNaN(F.load(from: largest.span)).isNaN)
        }

        #expect(F.smallestOrNaN(F.repeating(.infinity)) == .infinity)
        #expect(F.largestOrNaN(F.repeating(-.infinity)) == -.infinity)
    }

    @Test("A zero-masked maximum of a NaN is NaN on SVE2_128 and the other operand on NEON")
    func maskedMaximumOfNaN() {
        let isSVE = SIMDTarget.targetName == "SVE2_128"
        let isNEON = SIMDTarget.targetName.hasPrefix("NEON")
        expectMaskedMaximumOfNaN(Float.self, isNaN: isSVE, isNumber: isNEON)
        expectMaskedMaximumOfNaN(Double.self, isNaN: isSVE, isNumber: isNEON)
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        expectMaskedMaximumOfNaN(
            Float16.self,
            isNaN: isSVE,
            isNumber: isNEON && SIMDTarget.hasNativeFloat16Arithmetic
        )
        #endif
    }

    @Test("All bits clear counts a negative zero as clear, except on the AVX-512 targets")
    func allBitsClearOfNegativeZero() {
        let isClear = !SIMDTarget.targetName.hasPrefix("AVX3")
        expectAllBitsClearOfNegativeZero(Float.self, isClear: isClear)
        expectAllBitsClearOfNegativeZero(Double.self, isClear: isClear)
    }

    @Test("A repeated block fills every 128-bit block with its lanes")
    func repeatingBlock() {
        typealias H = SIMD<UInt8>
        typealias D = SIMD<Double>
        var output = ContiguousArray<UInt8>(repeating: 0, count: H.laneCount)
        var doubles = ContiguousArray<Double>(repeating: 0, count: D.laneCount)

        var destination = output.mutableSpan
        H.store(
            H.repeatingBlock(
                0x10,
                0x11,
                0x12,
                0x13,
                0x14,
                0x15,
                0x16,
                0x17,
                0x18,
                0x19,
                0x1A,
                0x1B,
                0x1C,
                0x1D,
                0x1E,
                0x1F
            ),
            to: &destination
        )
        var doubleDestination = doubles.mutableSpan
        D.store(D.repeatingBlock(-0.5, 2.25), to: &doubleDestination)

        #expect(Array(output) == (0..<H.laneCount).map { UInt8(0x10 + $0 % 16) })
        #expect(Array(doubles) == (0..<D.laneCount).map { $0 % 2 == 0 ? -0.5 : 2.25 })
    }

    @Test("A slide up moves the lanes up and zeroes the lanes it leaves behind")
    func slideUp() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let vector = H.load(from: input.span)

        for amount in 0..<lanes {
            var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var destination = output.mutableSpan
            H.store(H.slideUpLanes(vector, by: amount), to: &destination)
            #expect(Array(output.prefix(amount)) == [UInt8](repeating: 0, count: amount))
            #expect(Array(output.dropFirst(amount)) == Array(input.prefix(lanes - amount)))
        }

        var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
        var destination = output.mutableSpan
        H.store(H.slide1Up(vector), to: &destination)
        #expect(Array(output) == [0] + Array(input.prefix(lanes - 1)))
    }

    @Test("A slide down moves the lanes down and zeroes the lanes it leaves behind")
    func slideDown() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let vector = H.load(from: input.span)

        for amount in 0..<lanes {
            var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var destination = output.mutableSpan
            H.store(H.slideDownLanes(vector, by: amount), to: &destination)
            #expect(Array(output.prefix(lanes - amount)) == Array(input.dropFirst(amount)))
            #expect(Array(output.suffix(amount)) == [UInt8](repeating: 0, count: amount))
        }

        var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
        var destination = output.mutableSpan
        H.store(H.slide1Down(vector), to: &destination)
        #expect(Array(output) == Array(input.dropFirst()) + [0])
    }

    @Test("A slide up with a fill takes the lanes it leaves behind from the fill")
    func slideUpFilling() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let filler = ContiguousArray((0..<lanes).map { UInt8($0 &+ 0x41) })
        let vector = H.load(from: input.span)
        let fill = H.load(from: filler.span)

        for amount in 0..<lanes {
            var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var destination = output.mutableSpan
            H.store(H.slideUpLanes(vector, by: amount, fillingWith: fill), to: &destination)
            #expect(Array(output.prefix(amount)) == Array(filler.prefix(amount)))
            #expect(Array(output.dropFirst(amount)) == Array(input.prefix(lanes - amount)))
        }

        var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
        var destination = output.mutableSpan
        H.store(H.slide1Up(vector, fillingWith: 0x7F), to: &destination)
        #expect(Array(output) == [0x7F] + Array(input.prefix(lanes - 1)))
    }

    @Test("A slide down with a fill takes the lanes it leaves behind from the fill")
    func slideDownFilling() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let filler = ContiguousArray((0..<lanes).map { UInt8($0 &+ 0x41) })
        let vector = H.load(from: input.span)
        let fill = H.load(from: filler.span)

        for amount in 0..<lanes {
            var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var destination = output.mutableSpan
            H.store(H.slideDownLanes(vector, by: amount, fillingWith: fill), to: &destination)
            #expect(Array(output.prefix(lanes - amount)) == Array(input.dropFirst(amount)))
            #expect(Array(output.suffix(amount)) == Array(filler.suffix(amount)))
        }

        var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
        var destination = output.mutableSpan
        H.store(H.slide1Down(vector, fillingWith: 0x7F), to: &destination)
        #expect(Array(output) == Array(input.dropFirst()) + [0x7F])
    }

    @Test("An unchecked slide gives the lanes the checked one does")
    func uncheckedSlides() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let vector = H.load(from: input.span)

        for amount in 0..<lanes {
            var up = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var down = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var upDestination = up.mutableSpan
            var downDestination = down.mutableSpan
            H.store(unsafe H.slideUpLanes(vector, byUnchecked: amount), to: &upDestination)
            H.store(unsafe H.slideDownLanes(vector, byUnchecked: amount), to: &downDestination)
            let zeros = [UInt8](repeating: 0, count: amount)
            #expect(Array(up) == zeros + Array(input.prefix(lanes - amount)))
            #expect(Array(down) == Array(input.dropFirst(amount)) + zeros)
        }
    }

    @Test("An unchecked slide with a fill gives the lanes the checked one does")
    func uncheckedFillingSlides() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let filler = ContiguousArray((0..<lanes).map { UInt8($0 &+ 0x41) })
        let vector = H.load(from: input.span)
        let fill = H.load(from: filler.span)

        for amount in 0..<lanes {
            var up = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var down = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
            var upDestination = up.mutableSpan
            var downDestination = down.mutableSpan
            H.store(
                unsafe H.slideUpLanes(vector, byUnchecked: amount, fillingWith: fill),
                to: &upDestination
            )
            H.store(
                unsafe H.slideDownLanes(vector, byUnchecked: amount, fillingWith: fill),
                to: &downDestination
            )
            #expect(Array(up) == Array(filler.prefix(amount)) + Array(input.prefix(lanes - amount)))
            #expect(
                Array(down) == Array(input.dropFirst(amount)) + Array(filler.suffix(amount))
            )
        }
    }

    @Test("A partial load only reads the lanes it is asked for")
    func partialLoad() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        guard lanes > 3 else { return }
        let input = (0..<lanes).map { UInt8($0 &+ 1) }
        var output = [UInt8](repeating: 0xEE, count: lanes)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let v = unsafe H.loadFirst(from: source.baseAddress!, count: 3)
                unsafe H.storeFirst(v, to: destination.baseAddress!, count: 3)
            }
        }

        #expect(Array(output.prefix(3)) == Array(input.prefix(3)))
        #expect(output.dropFirst(3).allSatisfy { $0 == 0xEE })
    }

    @Test("A widening load promotes every lane it reads")
    func wideningLoad() {
        typealias H = SIMD<UInt32>
        typealias S = SIMD<Int64>
        let lanes = H.laneCount
        let unsigned = (0..<lanes).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 200) }
        let signed = (0..<S.laneCount).map { Int16(truncatingIfNeeded: $0 &* -3001 &- 1) }

        var widenedUnsigned = [UInt32](repeating: 0, count: lanes)
        var widenedSigned = [Int64](repeating: 0, count: S.laneCount)

        unsigned.withUnsafeBufferPointer { source in
            widenedUnsigned.withUnsafeMutableBufferPointer {
                unsafe H.store(H.loadWidening(from: source.baseAddress!), to: $0.baseAddress!)
            }
        }
        signed.withUnsafeBufferPointer { source in
            widenedSigned.withUnsafeMutableBufferPointer {
                unsafe S.store(S.loadWidening(from: source.baseAddress!), to: $0.baseAddress!)
            }
        }

        #expect(widenedUnsigned == unsigned.map(UInt32.init))
        #expect(widenedSigned == signed.map(Int64.init))
    }

    @Test("A partial widening load zeroes the lanes it is not asked for")
    func partialWideningLoad() {
        typealias H = SIMD<Double>
        let lanes = H.laneCount
        guard lanes > 1 else { return }
        let input = (0..<lanes).map { Float($0) + 0.5 }
        var output = [Double](repeating: -1, count: lanes)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer {
                let v = unsafe H.loadFirstWidening(from: source.baseAddress!, count: 1)
                unsafe H.store(v, to: $0.baseAddress!)
            }
        }

        #expect(output.first == Double(input[0]))
        #expect(output.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test("Interleaved load and store round trip three channels")
    func interleaved() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = (0..<(lanes * 3)).map { UInt8($0 & 0xFF) }
        var output = [UInt8](repeating: 0, count: lanes * 3)

        input.withUnsafeBufferPointer { source in
            var v0 = H.zero()
            var v1 = H.zero()
            var v2 = H.zero()
            unsafe H.loadInterleaved3(from: source.baseAddress!, &v0, &v1, &v2)
            output.withUnsafeMutableBufferPointer {
                unsafe H.storeInterleaved3(v0, v1, v2, to: $0.baseAddress!)
            }
        }

        #expect(output == input)
    }

    @Test("A vector survives a span store after a span load")
    func spanLoadStoreRoundTrip() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &* 3) })
        var output = ContiguousArray<UInt8>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        H.store(H.load(from: input.span), to: &destination)

        #expect(output == input)
    }

    @Test("A vector survives an unchecked span store after an unchecked span load")
    func uncheckedSpanLoadStoreRoundTrip() {
        typealias H = SIMD<Int32>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { Int32($0) - 2 })
        var output = ContiguousArray<Int32>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        unsafe H.store(H.load(fromUnchecked: input.span), toUnchecked: &destination)

        #expect(output == input)
    }

    @Test("A vector survives aligned span stores after aligned span loads")
    func alignedSpanLoadStoreRoundTrip() {
        typealias H = SIMD<UInt32>
        let lanes = H.laneCount
        let byteCount = lanes * MemoryLayout<UInt32>.stride
        let values = (0..<lanes).map { UInt32(truncatingIfNeeded: $0) &* 2_654_435_761 }
        let input =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount, alignment: byteCount)
            .initializeMemory(as: UInt32.self, fromContentsOf: values)
        let checked =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount, alignment: byteCount)
            .initializeMemory(as: UInt32.self, repeating: 0)
        let unchecked =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount, alignment: byteCount)
            .initializeMemory(as: UInt32.self, repeating: 0)
        defer {
            unsafe input.deallocate()
            unsafe checked.deallocate()
            unsafe unchecked.deallocate()
        }

        let source = unsafe input.span
        var checkedDestination = unsafe checked.mutableSpan
        H.storeAligned(H.loadAligned(from: source), to: &checkedDestination)
        var uncheckedDestination = unsafe unchecked.mutableSpan
        unsafe H.storeAligned(
            H.loadAligned(fromUnchecked: source),
            toUnchecked: &uncheckedDestination
        )

        #expect(unsafe Array(checked) == values)
        #expect(unsafe Array(unchecked) == values)
    }

    @Test("A span load reads the start of the span")
    func spanLoadReadsStart() {
        typealias H = SIMD<UInt16>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 5) })
        var output = ContiguousArray<UInt16>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        H.store(H.load(from: input.span.extracting(droppingFirst: lanes)), to: &destination)

        #expect(Array(output) == Array(input.dropFirst(lanes)))
    }

    @Test("A partial span load and store only touch the lanes the span has")
    func partialSpanLoadStore() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        guard lanes > 3 else { return }
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        var loaded = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
        var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)

        let vector = H.loadFirst(from: input.span.extracting(first: 3))
        var whole = loaded.mutableSpan
        H.store(vector, to: &whole)
        output.withUnsafeMutableBufferPointer { buffer in
            let prefix = unsafe UnsafeMutableBufferPointer(rebasing: buffer[0..<3])
            var destination = unsafe prefix.mutableSpan
            H.storeFirst(H.load(from: input.span), to: &destination)
        }

        #expect(Array(loaded.prefix(3)) == Array(input.prefix(3)))
        #expect(loaded.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(Array(output.prefix(3)) == Array(input.prefix(3)))
        #expect(output.dropFirst(3).allSatisfy { $0 == 0xEE })
    }

    @Test("A partial span load and store accept an empty span")
    func emptySpanLoadStore() {
        typealias H = SIMD<Float>
        let input = ContiguousArray<Float>()
        var output = ContiguousArray<Float>()

        let vector = H.loadFirst(from: input.span)
        var destination = output.mutableSpan
        H.storeFirst(vector, to: &destination)

        #expect(H.allTrue(H.equalTo(vector, H.zero())))
        #expect(output.isEmpty)
    }

    #if (os(Linux) || os(Android)) && _pointerBitWidth(_64)
    @Test("A partial span load and store of a span of 2^32 or more elements use a whole vector")
    func hugeSpanLoadStore() {
        guard SIMDTarget.targetName == "SVE2_128" else { return }
        typealias H = SIMD<UInt8>
        typealias W = SIMD<UInt16>
        let lanes = H.laneCount
        let wrapped = 1 << 32
        let byteCount = wrapped + lanes
        let mapped: UnsafeMutableRawPointer? = unsafe mmap(
            nil,
            byteCount,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
            -1,
            0
        )
        guard let mapped = unsafe mapped, unsafe mapped != UnsafeMutableRawPointer(bitPattern: -1)
        else { return }
        defer { unsafe _ = munmap(mapped, byteCount) }
        let bytes = unsafe mapped.bindMemory(to: UInt8.self, capacity: byteCount)
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })

        for count in [wrapped, wrapped + 1, wrapped + lanes] {
            for lane in 0..<lanes { unsafe bytes[lane] = input[lane] }
            for lane in lanes..<(lanes + 4) { unsafe bytes[lane] = 0xEE }
            let readable = unsafe UnsafeBufferPointer(start: bytes, count: count)
            var loaded = ContiguousArray<UInt8>(repeating: 0, count: lanes)
            var widened = ContiguousArray<UInt16>(repeating: 0, count: W.laneCount)

            var loadedDestination = loaded.mutableSpan
            H.store(H.loadFirst(from: unsafe readable.span), to: &loadedDestination)
            var widenedDestination = widened.mutableSpan
            W.store(W.loadFirstWidening(from: unsafe readable.span), to: &widenedDestination)
            #expect(Array(loaded) == Array(input))
            #expect(Array(widened) == input.prefix(W.laneCount).map(UInt16.init))

            for lane in 0..<lanes { unsafe bytes[lane] = 0 }
            let writable = unsafe UnsafeMutableBufferPointer(start: bytes, count: count)
            var destination = unsafe writable.mutableSpan
            H.storeFirst(H.load(from: input.span), to: &destination)
            #expect((0..<lanes).allSatisfy { unsafe bytes[$0] == input[$0] })
            #expect((lanes..<(lanes + 4)).allSatisfy { unsafe bytes[$0] == 0xEE })
        }
    }
    #endif

    @Test("A widening span load promotes every lane it reads")
    func spanWideningLoad() {
        typealias H = SIMD<UInt32>
        typealias S = SIMD<Int64>
        let unsigned = ContiguousArray(
            (0..<H.laneCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 200) }
        )
        let signed = ContiguousArray(
            (0..<S.laneCount).map { Int16(truncatingIfNeeded: $0 &* -3001 &- 1) }
        )
        var widenedUnsigned = ContiguousArray<UInt32>(repeating: 0, count: H.laneCount)
        var widenedSigned = ContiguousArray<Int64>(repeating: 0, count: S.laneCount)

        var unsignedDestination = widenedUnsigned.mutableSpan
        H.store(H.loadWidening(from: unsigned.span), to: &unsignedDestination)
        var signedDestination = widenedSigned.mutableSpan
        unsafe S.store(S.loadWidening(fromUnchecked: signed.span), to: &signedDestination)

        #expect(Array(widenedUnsigned) == unsigned.map(UInt32.init))
        #expect(Array(widenedSigned) == signed.map(Int64.init))
    }

    @Test("A partial widening span load zeroes the lanes the span does not have")
    func partialSpanWideningLoad() {
        typealias H = SIMD<Double>
        let lanes = H.laneCount
        guard lanes > 1 else { return }
        let input = ContiguousArray((0..<lanes).map { Float($0) + 0.5 })
        var output = ContiguousArray<Double>(repeating: -1, count: lanes)

        var destination = output.mutableSpan
        H.store(H.loadFirstWidening(from: input.span.extracting(first: 1)), to: &destination)

        #expect(output.first == Double(input[0]))
        #expect(output.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test("Interleaved span load and store round trip three channels")
    func spanInterleaved() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 3)).map { UInt8($0 & 0xFF) })
        var output = ContiguousArray<UInt8>(repeating: 0, count: lanes * 3)

        var v0 = H.zero()
        var v1 = H.zero()
        var v2 = H.zero()
        H.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        var destination = output.mutableSpan
        H.storeInterleaved3(v0, v1, v2, to: &destination)

        #expect(output == input)
    }

    @Test("Unchecked interleaved span load and store round trip two channels")
    func uncheckedSpanInterleaved() {
        typealias H = SIMD<UInt16>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 7) })
        var output = ContiguousArray<UInt16>(repeating: 0, count: lanes * 2)

        var v0 = H.zero()
        var v1 = H.zero()
        unsafe H.loadInterleaved2(fromUnchecked: input.span, &v0, &v1)
        var destination = output.mutableSpan
        unsafe H.storeInterleaved2(v0, v1, toUnchecked: &destination)

        #expect(output == input)
    }

    @Test("A vector survives appends to an output span after a span load")
    func outputSpanAppendRoundTrip() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &* 3) })

        let output = ContiguousArray<UInt8>(capacity: lanes * 2) { output in
            H.append(H.load(from: input.span), to: &output)
            unsafe H.append(H.load(from: input.span), toUnchecked: &output)
        }

        #expect(output == input + input)
    }

    @Test("An append of a count to an output span only touches that many lanes")
    func partialOutputSpanAppend() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        guard lanes > 3 else { return }
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: lanes * 2)
        unsafe buffer.initialize(repeating: 0xEE)
        defer { unsafe buffer.deallocate() }

        var output = unsafe OutputSpan(buffer: buffer, initializedCount: 0)
        H.append(H.load(from: input.span), addingCount: 3, to: &output)
        H.append(H.load(from: input.span), addingCount: 0, to: &output)
        unsafe H.append(H.load(from: input.span), addingCount: lanes, toUnchecked: &output)
        let count = unsafe output.finalize(for: buffer)

        #expect(count == 3 + lanes)
        #expect(unsafe Array(buffer[0..<3]) == Array(input.prefix(3)))
        #expect(unsafe Array(buffer[3..<(3 + lanes)]) == Array(input))
        #expect(unsafe buffer[(3 + lanes)...].allSatisfy { $0 == 0xEE })
    }

    @Test("An append of no lanes accepts an output span without a buffer")
    func emptyOutputSpanAppend() {
        typealias H = SIMD<Float>
        var output = OutputSpan<Float>()

        H.append(H.zero(), addingCount: 0, to: &output)
        unsafe H.append(H.zero(), addingCount: 0, toUnchecked: &output)
        let isEmpty = output.isEmpty

        #expect(isEmpty)
    }

    @Test("Aligned appends to an output span continue at aligned addresses")
    func alignedOutputSpanAppend() {
        typealias H = SIMD<UInt32>
        let lanes = H.laneCount
        let byteCount = lanes * MemoryLayout<UInt32>.stride
        let values = (0..<lanes).map { UInt32(truncatingIfNeeded: $0) &* 2_654_435_761 }
        let input = ContiguousArray(values)
        let buffer =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount * 2, alignment: byteCount)
            .bindMemory(to: UInt32.self)
        defer { unsafe buffer.deallocate() }

        var output = unsafe OutputSpan(buffer: buffer, initializedCount: 0)
        H.appendAligned(H.load(from: input.span), to: &output)
        unsafe H.appendAligned(H.load(from: input.span), toUnchecked: &output)
        let count = unsafe output.finalize(for: buffer)

        #expect(count == lanes * 2)
        #expect(unsafe Array(buffer) == values + values)
    }

    @Test("Interleaved appends to an output span round trip three channels")
    func outputSpanInterleaved() {
        typealias H = SIMD<UInt8>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 3)).map { UInt8($0 & 0xFF) })

        var v0 = H.zero()
        var v1 = H.zero()
        var v2 = H.zero()
        H.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        let output = ContiguousArray<UInt8>(capacity: lanes * 3) { output in
            H.appendInterleaved3(v0, v1, v2, to: &output)
        }

        #expect(output == input)
    }

    @Test("Unchecked interleaved appends to an output span round trip two channels")
    func uncheckedOutputSpanInterleaved() {
        typealias H = SIMD<UInt16>
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 7) })

        var v0 = H.zero()
        var v1 = H.zero()
        unsafe H.loadInterleaved2(fromUnchecked: input.span, &v0, &v1)
        let output = ContiguousArray<UInt16>(capacity: lanes * 2) { output in
            unsafe H.appendInterleaved2(v0, v1, toUnchecked: &output)
        }

        #expect(output == input)
    }

    @Test("A 4-lane reversal reverses every group of 4 lanes of 64 bits")
    func reversed4Of64BitLanes() {
        typealias U = SIMD<UInt64>
        typealias I = SIMD<Int64>
        typealias D = SIMD<Double>
        guard U.canReverse4, I.canReverse4, D.canReverse4 else { return }
        let unsigned = ContiguousArray(
            (0..<U.laneCount).map { UInt64($0) &* 0x0101_0101_0101_0101 }
        )
        let signed = ContiguousArray((0..<I.laneCount).map { Int64($0) - 3 })
        let doubles = ContiguousArray((0..<D.laneCount).map { Double($0) - 2.5 })

        #expect(
            lanes(U.reversed4(U.load(from: unsigned.span)))
                == unsigned.indices.map { unsigned[$0 ^ 3] }
        )
        #expect(
            lanes(I.reversed4(I.load(from: signed.span)))
                == signed.indices.map { signed[$0 ^ 3] }
        )
        #expect(
            lanes(D.reversed4(D.load(from: doubles.span)))
                == doubles.indices.map { doubles[$0 ^ 3] }
        )
    }

    @Test("An 8-lane reversal reverses every group of 8 lanes of 32 bits")
    func reversed8Of32BitLanes() {
        typealias U = SIMD<UInt32>
        typealias I = SIMD<Int32>
        typealias F = SIMD<Float>
        guard U.canReverse8, I.canReverse8, F.canReverse8 else { return }
        let unsigned = ContiguousArray((0..<U.laneCount).map { UInt32($0) &* 0x0101_0101 })
        let signed = ContiguousArray((0..<I.laneCount).map { Int32($0) - 5 })
        let floats = ContiguousArray((0..<F.laneCount).map { Float($0) * 0.5 - 3 })

        #expect(
            lanes(U.reversed8(U.load(from: unsigned.span)))
                == unsigned.indices.map { unsigned[$0 ^ 7] }
        )
        #expect(
            lanes(I.reversed8(I.load(from: signed.span)))
                == signed.indices.map { signed[$0 ^ 7] }
        )
        #expect(
            lanes(F.reversed8(F.load(from: floats.span)))
                == floats.indices.map { floats[$0 ^ 7] }
        )
    }

    @Test("An 8-lane reversal reverses every group of 8 lanes of 64 bits")
    func reversed8Of64BitLanes() {
        typealias U = SIMD<UInt64>
        typealias I = SIMD<Int64>
        typealias D = SIMD<Double>
        guard U.canReverse8, I.canReverse8, D.canReverse8 else { return }
        let unsigned = ContiguousArray(
            (0..<U.laneCount).map { UInt64($0) &* 0x0101_0101_0101_0101 }
        )
        let signed = ContiguousArray((0..<I.laneCount).map { Int64($0) - 3 })
        let doubles = ContiguousArray((0..<D.laneCount).map { Double($0) - 2.5 })

        #expect(
            lanes(U.reversed8(U.load(from: unsigned.span)))
                == unsigned.indices.map { unsigned[$0 ^ 7] }
        )
        #expect(
            lanes(I.reversed8(I.load(from: signed.span)))
                == signed.indices.map { signed[$0 ^ 7] }
        )
        #expect(
            lanes(D.reversed8(D.load(from: doubles.span)))
                == doubles.indices.map { doubles[$0 ^ 7] }
        )
    }

    @Test("An 8-lane reversal reverses every group of 8 bfloat16 lanes")
    func reversed8OfBFloat16Lanes() {
        typealias H = SIMD<BFloat16>
        guard H.canReverse8 else { return }
        let input = ContiguousArray((0..<H.laneCount).map { BFloat16(Float($0) - 2.5) })
        let output = ContiguousArray<BFloat16>(capacity: H.laneCount) { output in
            H.append(H.reversed8(H.load(from: input.span)), to: &output)
        }

        #expect(Array(output) == input.indices.map { input[$0 ^ 7] })
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @Test("An 8-lane reversal reverses every group of 8 float16 lanes")
    func reversed8OfFloat16Lanes() {
        typealias H = SIMD<Float16>
        guard H.canReverse8 else { return }
        let input = ContiguousArray((0..<H.laneCount).map { Float16($0) - 2.5 })

        #expect(
            lanes(H.reversed8(H.load(from: input.span)))
                == input.indices.map { input[$0 ^ 7] }
        )
    }
    #endif

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked span ops trap on a span that is too short")
    func checkedSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMD<UInt8>.laneCount - 1)
            _ = SIMD<UInt8>.load(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<UInt8>(repeating: 0, count: SIMD<UInt8>.laneCount - 1)
            var destination = output.mutableSpan
            SIMD<UInt8>.store(SIMD<UInt8>.zero(), to: &destination)
        }
        await #expect(processExitsWith: .failure) {
            let count = SIMD<UInt8>.laneCount * 3 - 1
            let input = ContiguousArray<UInt8>(repeating: 0, count: count)
            var v0 = SIMD<UInt8>.zero()
            var v1 = SIMD<UInt8>.zero()
            var v2 = SIMD<UInt8>.zero()
            SIMD<UInt8>.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        }
        await #expect(processExitsWith: .failure) {
            let count = SIMD<UInt8>.laneCount * 2 - 1
            var output = ContiguousArray<UInt8>(repeating: 0, count: count)
            var destination = output.mutableSpan
            let zero = SIMD<UInt8>.zero()
            SIMD<UInt8>.storeInterleaved2(zero, zero, to: &destination)
        }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMD<UInt32>.laneCount - 1)
            _ = SIMD<UInt32>.loadWidening(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            let count = (SIMD<UInt8>.laneCount + 7) / 8 - 1
            let input = ContiguousArray<UInt8>(repeating: 0, count: count)
            _ = SIMD<UInt8>.loadMask(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            let count = (SIMD<UInt8>.laneCount + 7) / 8 - 1
            var output = ContiguousArray<UInt8>(repeating: 0, count: count)
            var destination = output.mutableSpan
            _ = SIMD<UInt8>.storeMask(SIMD<UInt8>.repeatingMask(true), to: &destination)
        }
    }

    @Test("Checked aligned span ops trap on a misaligned span")
    func checkedAlignedSpanOpsTrap() async {
        guard SIMD<UInt8>.laneCount > 1 else { return }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMD<UInt8>.laneCount * 2)
            _ = SIMD<UInt8>.loadAligned(from: input.span.extracting(droppingFirst: 1))
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<UInt8>(repeating: 0, count: SIMD<UInt8>.laneCount * 2)
            output.withUnsafeMutableBufferPointer { buffer in
                let shifted = unsafe UnsafeMutableBufferPointer(rebasing: buffer[1...])
                var destination = unsafe shifted.mutableSpan
                SIMD<UInt8>.storeAligned(SIMD<UInt8>.zero(), to: &destination)
            }
        }
    }

    @Test("A lookup reads the table at the indices through every form")
    func lookupReadsTable() {
        typealias H = SIMD<UInt32>
        guard H.canLookup8 else { return }
        let table = (0..<8).map { UInt32($0 &* 7) &+ 100 }
        let indices = ContiguousArray((0..<H.laneCount).map { UInt32(($0 &* 3) % 8) })
        let expected = indices.map { table[Int($0)] }
        let vector = H.load(from: indices.span)

        withAlignedTable(table) { span in
            #expect(lanes(H.lookup8(at: vector, from: span)) == expected)
            #expect(lanes(unsafe H.lookup8(at: vector, fromUnchecked: span)) == expected)
            span.withUnsafeBufferPointer { pointer in
                let result = unsafe H.lookup8(at: vector, from: pointer.baseAddress!)
                #expect(lanes(result) == expected)
            }
        }
    }

    @Test("A 16-lane lookup reads the table at the indices through every form")
    func lookup16ReadsTable() {
        typealias H = SIMD<UInt16>
        guard H.canLookup16 else { return }
        let table = (0..<16).map { UInt16($0 &* 7) &+ 100 }
        let indices = ContiguousArray((0..<H.laneCount).map { UInt16(($0 &* 5) % 16) })
        let expected = indices.map { table[Int($0)] }
        let vector = H.load(from: indices.span)

        withAlignedTable(table) { span in
            #expect(lanes(H.lookup16(at: vector, from: span)) == expected)
            #expect(lanes(unsafe H.lookup16(at: vector, fromUnchecked: span)) == expected)
            span.withUnsafeBufferPointer { pointer in
                let result = unsafe H.lookup16(at: vector, from: pointer.baseAddress!)
                #expect(lanes(result) == expected)
            }
        }
    }

    @Test("A 32-lane lookup reads the table at the indices through every form")
    func lookup32ReadsTable() {
        typealias H = SIMD<UInt8>
        guard H.canLookup32 else { return }
        let table = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7) &+ 100 }
        let indices = ContiguousArray((0..<H.laneCount).map { UInt8(($0 &* 5) % 32) })
        let expected = indices.map { table[Int($0)] }
        let vector = H.load(from: indices.span)

        withAlignedTable(table) { span in
            #expect(lanes(H.lookup32(at: vector, from: span)) == expected)
            #expect(lanes(unsafe H.lookup32(at: vector, fromUnchecked: span)) == expected)
            span.withUnsafeBufferPointer { pointer in
                let result = unsafe H.lookup32(at: vector, from: pointer.baseAddress!)
                #expect(lanes(result) == expected)
            }
        }
    }

    @Test("A 64-lane lookup reads the table at the indices through every form")
    func lookup64ReadsTable() {
        typealias H = SIMD<UInt8>
        guard H.canLookup64 else { return }
        let table = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 7) &+ 100 }
        let indices = ContiguousArray((0..<H.laneCount).map { UInt8(($0 &* 5) % 64) })
        let expected = indices.map { table[Int($0)] }
        let vector = H.load(from: indices.span)

        withAlignedTable(table) { span in
            #expect(lanes(H.lookup64(at: vector, from: span)) == expected)
            #expect(lanes(unsafe H.lookup64(at: vector, fromUnchecked: span)) == expected)
            span.withUnsafeBufferPointer { pointer in
                let result = unsafe H.lookup64(at: vector, from: pointer.baseAddress!)
                #expect(lanes(result) == expected)
            }
        }
    }

    @Test("Loaded indices hold the lanes of the span through every form")
    func loadIndicesReadsLanes() {
        typealias H = SIMD<UInt32>
        let indices = ContiguousArray((0..<H.laneCount).map { UInt32(H.laneCount - 1 - $0) })

        #expect(lanes(H.loadIndices(from: indices.span)) == Array(indices))
        #expect(
            lanes(unsafe H.loadIndices(fromUnchecked: indices.span)) == Array(indices)
        )
        indices.withUnsafeBufferPointer { pointer in
            let result = unsafe H.loadIndices(from: pointer.baseAddress!)
            #expect(lanes(result) == Array(indices))
        }
    }

    @Test("Loaded indices may select the lanes of a second table, below 2 * laneCount")
    func loadIndicesSelectSecondTable() {
        typealias H = SIMD<UInt32>
        let last = ContiguousArray((0..<H.laneCount).map { UInt32(2 * H.laneCount - 1 - $0) })
        let first = H.iota(0)
        let second = H.iota(UInt32(H.laneCount))

        #expect(
            lanes(H.twoTablesLookupLanes(first, second, at: H.loadIndices(from: last.span)))
                == Array(last)
        )
    }

    @Test("Checked lookups trap on a short or misaligned table or an index outside it")
    func checkedLookupsTrap() async {
        await #expect(processExitsWith: .failure) {
            withAlignedTable([UInt32](repeating: 0, count: 7)) { span in
                _ = SIMD<UInt32>.lookup8(at: SIMD<UInt32>.zero(), from: span)
            }
        }
        await #expect(processExitsWith: .failure) {
            let table = ContiguousArray<UInt32>(repeating: 0, count: 16)
            _ = SIMD<UInt32>.lookup8(
                at: SIMD<UInt32>.zero(),
                from: table.span.extracting(droppingFirst: 1)
            )
        }
        await #expect(processExitsWith: .failure) {
            withAlignedTable([UInt32](repeating: 0, count: 8)) { span in
                _ = SIMD<UInt32>.lookup8(at: SIMD<UInt32>.repeating(8), from: span)
            }
        }
    }

    @Test("Reversals trap where a vector has too few lanes for them")
    func reversalsTrapWithTooFewLanes() async {
        if !SIMD<UInt64>.canReverse4 {
            await #expect(processExitsWith: .failure) {
                _ = SIMD<UInt64>.reversed4(SIMD<UInt64>.zero())
            }
        }
        if !SIMD<UInt32>.canReverse8 {
            await #expect(processExitsWith: .failure) {
                _ = SIMD<UInt32>.reversed8(SIMD<UInt32>.zero())
            }
        }
    }

    @Test("Checked immediate ops trap on an immediate that is out of range")
    func checkedImmediateOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.shiftedLeftBytes(SIMD<UInt8>.zero(), by: 17)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.shiftedRightBytes(SIMD<UInt8>.zero(), by: -1)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt8>.zero()
            _ = SIMD<UInt8>.combinedShiftedRightBytes(zero, zero, by: 0)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.broadcastingInBlocks(SIMD<UInt32>.zero(), lane: 4)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.broadcasting(SIMD<UInt32>.zero(), lane: SIMD<UInt32>.laneCount)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.slideUpBlocks(SIMD<UInt32>.zero(), by: SIMD<UInt32>.laneCount / 4)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.shuffledPer4Lanes(SIMD<UInt32>.zero(), 0, 4, 0, 0)
        }
    }

    @Test("Checked shift-and-demote ops trap on a shift amount that is out of range")
    func checkedShiftAndDemoteOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<Int16>.zero()
            _ = SIMD<Int8>.vector(clamping: zero, zero, shiftedRightBy: 16)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt16>.vector(clamping: zero, zero, roundingShiftedRightBy: -1)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<Int64>.zero()
            _ = SIMD<Int32>.vector(clampingInAnyOrder: zero, zero, shiftedRightBy: 64)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt16>.zero()
            _ = SIMD<UInt8>.vector(clampingInAnyOrder: zero, zero, roundingShiftedRightBy: 16)
        }
    }

    @Test("Checked lane ops trap on an index outside 0..<laneCount")
    func checkedLaneOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.lane(SIMD<UInt32>.zero(), at: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.lane(SIMD<UInt32>.zero(), at: SIMD<UInt32>.laneCount)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.replacingLane(SIMD<UInt32>.zero(), at: -1, with: 1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.replacingLane(SIMD<UInt32>.zero(), at: SIMD<UInt32>.laneCount, with: 1)
        }
    }

    @Test("Checked tuple ops trap on an index outside 0..<N")
    func checkedTupleOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.get2(SIMD<UInt32>.create2(zero, zero), at: -1)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.get2(SIMD<UInt32>.create2(zero, zero), at: 2)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.get3(SIMD<UInt32>.create3(zero, zero, zero), at: -1)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.get3(SIMD<UInt32>.create3(zero, zero, zero), at: 3)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.get4(SIMD<UInt32>.create4(zero, zero, zero, zero), at: -1)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.get4(SIMD<UInt32>.create4(zero, zero, zero, zero), at: 4)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.set2(SIMD<UInt32>.create2(zero, zero), at: -1, to: zero)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.set2(SIMD<UInt32>.create2(zero, zero), at: 2, to: zero)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.set3(SIMD<UInt32>.create3(zero, zero, zero), at: -1, to: zero)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.set3(SIMD<UInt32>.create3(zero, zero, zero), at: 3, to: zero)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.set4(SIMD<UInt32>.create4(zero, zero, zero, zero), at: -1, to: zero)
        }
        await #expect(processExitsWith: .failure) {
            let zero = SIMD<UInt32>.zero()
            _ = SIMD<UInt32>.set4(SIMD<UInt32>.create4(zero, zero, zero, zero), at: 4, to: zero)
        }
    }

    @Test("Checked gathers and scatters trap on an index or a byte offset outside the span")
    func checkedGathersAndScattersTrap() async {
        await #expect(processExitsWith: .failure) {
            let source = ContiguousArray<UInt32>(repeating: 0, count: SIMD<UInt32>.laneCount)
            _ = SIMD<UInt32>.gather(from: source.span, indices: SIMD<Int32>.iota(1))
        }
        await #expect(processExitsWith: .failure) {
            let source = ContiguousArray<Float>(repeating: 0, count: SIMD<Float>.laneCount)
            let offset = SIMD<Int32>.repeating(Int32(SIMD<Float>.laneCount * 4 - 3))
            _ = SIMD<Float>.gather(from: source.span, byteOffsets: offset)
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<Int32>(repeating: 0, count: SIMD<Int32>.laneCount)
            var destination = output.mutableSpan
            SIMD<Int32>.scatter(
                SIMD<Int32>.zero(),
                to: &destination,
                indices: SIMD<Int32>.repeating(-1)
            )
        }
        await #expect(processExitsWith: .failure) {
            let source = ContiguousArray<Double>(repeating: 0, count: SIMD<Double>.laneCount)
            _ = SIMD<Double>.gather(
                from: source.span,
                indices: SIMD<Int64>.repeating(Int64(SIMD<Double>.laneCount)),
                where: SIMD<Double>.firstLanes(count: 1)
            )
        }
    }

    @Test("Checked masked gathers and scatters trap on an index outside the span in any mask lane")
    func checkedMaskedGathersAndScattersTrap() async {
        await #expect(processExitsWith: .failure) {
            let lanes = SIMD<UInt32>.laneCount
            let source = ContiguousArray<UInt32>(repeating: 0, count: lanes)
            let bits = ContiguousArray((0..<lanes).map { $0 == 0 ? UInt32(0x8000_0000) : 0 })
            let mask = SIMD<UInt32>.mask(from: SIMD<UInt32>.load(from: bits.span))
            _ = SIMD<UInt32>.gather(
                from: source.span,
                indices: SIMD<Int32>.repeating(Int32(lanes)),
                where: mask
            )
        }
        await #expect(processExitsWith: .failure) {
            let lanes = SIMD<Double>.laneCount
            var output = ContiguousArray<Double>(repeating: 0, count: lanes)
            var destination = output.mutableSpan
            let negative = -Double.leastNonzeroMagnitude
            let bits = ContiguousArray((0..<lanes).map { $0 == 0 ? negative : 0 })
            let mask = SIMD<Double>.mask(from: SIMD<Double>.load(from: bits.span))
            SIMD<Double>.scatter(
                SIMD<Double>.zero(),
                to: &destination,
                indices: SIMD<Int64>.repeating(Int64(lanes)),
                where: mask
            )
        }
    }

    @Test("Checked indices ops trap on an index outside 0..<2 * laneCount")
    func checkedIndicesOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMD<Int32>.indices(from: SIMD<Int32>.repeating(-1))
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt32>.indices(
                from: SIMD<UInt32>.repeating(UInt32(2 * SIMD<UInt32>.laneCount))
            )
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<Float>.indices(from: SIMD<Int32>.repeating(Int32(2 * SIMD<Float>.laneCount)))
        }
    }

    @Test("Checked index loads trap on an index outside 0..<2 * laneCount")
    func checkedIndexLoadsTrap() async {
        await #expect(processExitsWith: .failure) {
            let indices = ContiguousArray(
                repeating: UInt32(2 * SIMD<UInt32>.laneCount),
                count: SIMD<UInt32>.laneCount
            )
            _ = SIMD<UInt32>.loadIndices(from: indices.span)
        }
        await #expect(processExitsWith: .failure) {
            let indices = ContiguousArray<Int32>(repeating: -1, count: SIMD<Int32>.laneCount)
            _ = SIMD<Int32>.loadIndices(from: indices.span)
        }
    }

    @Test("Checked output span ops trap on too little free capacity or a count out of bounds")
    func checkedOutputSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: SIMD<UInt8>.laneCount - 1) { output in
                SIMD<UInt8>.append(SIMD<UInt8>.zero(), to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: SIMD<UInt8>.laneCount * 2 - 1) { output in
                let zero = SIMD<UInt8>.zero()
                SIMD<UInt8>.appendInterleaved2(zero, zero, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: 2) { output in
                SIMD<UInt8>.append(SIMD<UInt8>.zero(), addingCount: 3, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: SIMD<UInt8>.laneCount * 2) { output in
                let count = SIMD<UInt8>.laneCount + 1
                SIMD<UInt8>.append(SIMD<UInt8>.zero(), addingCount: count, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: 1) { output in
                SIMD<UInt8>.append(SIMD<UInt8>.zero(), addingCount: -1, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: (SIMD<UInt8>.laneCount + 7) / 8 - 1) { output in
                SIMD<UInt8>.appendMask(SIMD<UInt8>.repeatingMask(true), to: &output)
            }
        }
    }

    @Test("Checked lane amount ops trap on an amount outside 0...laneCount")
    func checkedLaneAmountOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideUpLanes(SIMD<UInt8>.repeatingMask(true), by: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideDownLanes(
                SIMD<UInt8>.repeatingMask(true),
                by: SIMD<UInt8>.laneCount + 1
            )
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideUpLanes(SIMD<UInt8>.zero(), by: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideUpLanes(SIMD<UInt8>.zero(), by: SIMD<UInt8>.laneCount + 1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideDownLanes(SIMD<UInt8>.zero(), by: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideDownLanes(SIMD<UInt8>.zero(), by: SIMD<UInt8>.laneCount + 1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideUpLanes(
                SIMD<UInt8>.zero(),
                by: -1,
                fillingWith: SIMD<UInt8>.zero()
            )
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideUpLanes(
                SIMD<UInt8>.zero(),
                by: SIMD<UInt8>.laneCount + 1,
                fillingWith: SIMD<UInt8>.zero()
            )
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideDownLanes(
                SIMD<UInt8>.zero(),
                by: -1,
                fillingWith: SIMD<UInt8>.zero()
            )
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.slideDownLanes(
                SIMD<UInt8>.zero(),
                by: SIMD<UInt8>.laneCount + 1,
                fillingWith: SIMD<UInt8>.zero()
            )
        }
    }

    @Test("Checked aligned appends trap on an output span that continues misaligned")
    func checkedAlignedOutputSpanAppendTraps() async {
        guard SIMD<UInt8>.laneCount > 1 else { return }
        await #expect(processExitsWith: .failure) {
            let lanes = SIMD<UInt8>.laneCount
            let buffer =
                unsafe UnsafeMutableRawBufferPointer
                .allocate(byteCount: lanes * 2, alignment: lanes)
                .bindMemory(to: UInt8.self)
            unsafe buffer.initialize(repeating: 0)
            var output = unsafe OutputSpan(buffer: buffer, initializedCount: 1)
            SIMD<UInt8>.appendAligned(SIMD<UInt8>.zero(), to: &output)
        }
    }
    #endif
}

private func verifyWrappingComplexProducts<Lane: SIMDIntegerElement & FixedWidthInteger>(
    _ type: Lane.Type
) {
    typealias H = SIMD<Lane>

    let extremes: [Lane] = [.max, .min, .max / 3, .min / 3 + 1, .min / 7, 33, -1, .max - 7]
    let pick = { (offset: Int) in
        ContiguousArray((0..<H.laneCount).map { extremes[($0 &* 3 &+ offset) % extremes.count] })
    }
    let (a, b, c) = (pick(0), pick(5), pick(2))
    var products: [Lane] = []
    var conjugates: [Lane] = []
    for pair in stride(from: 0, to: H.laneCount, by: 2) {
        let (u, v, x, y) = (a[pair], a[pair + 1], b[pair], b[pair + 1])
        products += [u &* x &- v &* y, u &* y &+ v &* x]
        conjugates += [u &* x &+ v &* y, v &* x &- u &* y]
    }
    let (va, vb, vc) = (H.load(from: a.span), H.load(from: b.span), H.load(from: c.span))

    #expect(lanes(H.multiplyingComplex(va, vb)) == products)
    #expect(lanes(H.multiplyingComplexConjugate(va, vb)) == conjugates)
    #expect(lanes(H.multiplyAddingComplex(va, vb, vc)) == zip(products, c).map(&+))
    #expect(
        lanes(H.multiplyAddingComplexConjugate(va, vb, vc)) == zip(conjugates, c).map(&+)
    )
}

private func lanes<Lane: SIMDElement>(_ vector: SIMD<Lane>) -> [Lane] {
    let output = ContiguousArray<Lane>(capacity: SIMD<Lane>.laneCount) { output in
        SIMD<Lane>.append(vector, to: &output)
    }
    return Array(output)
}

private func expectMaskedMaximumOfNaN<Lane: SIMDNumericElement & BinaryFloatingPoint>(
    _ type: Lane.Type,
    isNaN: Bool,
    isNumber: Bool
) {
    typealias H = SIMD<Lane>

    let numbers = ContiguousArray((0..<H.laneCount).map { Lane($0) + 1.5 })
    let number = H.load(from: numbers.span)
    let mask = H.repeatingMask(true)
    for nanLane in 0..<H.laneCount {
        var lanes = numbers
        lanes[nanLane] = .nan
        let nan = H.load(from: lanes.span)
        for (a, b) in [(nan, number), (number, nan)] {
            let maximum = H.lane(H.maximum(a, b, where: mask), at: nanLane)
            if isNaN {
                #expect(maximum.isNaN, "\(H.self) lane \(nanLane) is \(maximum)")
            }
            if isNumber {
                #expect(maximum == numbers[nanLane], "\(H.self) lane \(nanLane) is \(maximum)")
            }
        }
    }
}

private func expectAllBitsClearOfNegativeZero<Lane: SIMDNumericElement & BinaryFloatingPoint>(
    _ type: Lane.Type,
    isClear: Bool
) {
    typealias H = SIMD<Lane>

    #expect(H.allBitsClear(H.repeating(-0.0)) == isClear, "\(H.self) of negative zeros")
    for lane in 0..<H.laneCount {
        var lanes = ContiguousArray(repeating: Lane(0), count: H.laneCount)
        lanes[lane] = -0.0
        #expect(
            H.allBitsClear(H.load(from: lanes.span)) == isClear,
            "\(H.self) with a negative zero in lane \(lane)"
        )
    }
}

private func withAlignedTable<Lane, Result>(
    _ lanes: [Lane],
    _ body: (Span<Lane>) -> Result
) -> Result {
    let table =
        unsafe UnsafeMutableRawBufferPointer
        .allocate(byteCount: lanes.count * MemoryLayout<Lane>.stride, alignment: 64)
        .initializeMemory(as: Lane.self, fromContentsOf: lanes)
    defer { unsafe table.deallocate() }
    return body(unsafe table.span)
}
