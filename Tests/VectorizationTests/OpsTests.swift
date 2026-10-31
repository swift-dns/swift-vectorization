import Testing
import Vectorization

@Suite("Ops")
struct OpsTests {
    @Test("A vector survives a store after a load")
    func loadStoreRoundTrip() {
        typealias H = SIMDUInt8
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
        typealias H = SIMDInt32
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
        typealias H = SIMDUInt64
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
        typealias H = SIMDUInt64
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
        typealias H = SIMDUInt32
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
        func check<H: SIMDIntegerElement>(_ type: H.Type) where H.Lane: FixedWidthInteger {
            let lanes = H.laneCount
            let a = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let b = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 91 &+ 5) })
            let c = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 53 &+ 29) })
            var output = ContiguousArray<H.Lane>(repeating: 0, count: lanes)

            var destination = output.mutableSpan
            H.store(
                H.bitwiseAndXor(H.load(from: a.span), H.load(from: b.span), H.load(from: c.span)),
                to: &destination
            )

            #expect(Array(output) == (0..<lanes).map { a[$0] & (b[$0] ^ c[$0]) })
        }

        check(SIMDUInt32.self)
        check(SIMDInt8.self)
    }

    @Test("A masked bitwise op zeroes the lanes the mask does not select")
    func maskedBitwise() {
        func check<H: SIMDIntegerElement>(_ type: H.Type) where H.Lane: FixedWidthInteger {
            let lanes = H.laneCount
            let selected = lanes / 2
            let a = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let b = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 91 &+ 5) })
            let mask = H.firstLanes(count: selected)
            let operations: [(vector: H.Vector, scalar: (H.Lane, H.Lane) -> H.Lane)] = [
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
                var output = ContiguousArray<H.Lane>(repeating: 1, count: lanes)
                var destination = output.mutableSpan
                H.store(operation.vector, to: &destination)
                let expected = (0..<lanes).map { lane in
                    lane < selected ? operation.scalar(a[lane], b[lane]) : 0
                }
                #expect(Array(output) == expected)
            }
        }

        check(SIMDUInt16.self)
        check(SIMDInt64.self)
    }

    @Test("A masked bitwise op takes the lanes the mask does not select from otherwise")
    func maskedBitwiseOtherwise() {
        func check<H: SIMDIntegerElement>(_ type: H.Type) where H.Lane: FixedWidthInteger {
            let lanes = H.laneCount
            let selected = lanes / 2
            let a = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let b = ContiguousArray((0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 91 &+ 5) })
            let other = ContiguousArray(
                (0..<lanes).map { H.Lane(truncatingIfNeeded: $0 &* 53 &+ 29) }
            )
            let mask = H.firstLanes(count: selected)
            let (va, vb, vo) = (
                H.load(from: a.span), H.load(from: b.span), H.load(from: other.span)
            )
            let operations: [(vector: H.Vector, scalar: (H.Lane, H.Lane) -> H.Lane)] = [
                (H.bitwiseAnd(va, vb, where: mask, otherwise: vo), { $0 & $1 }),
                (H.bitwiseOr(va, vb, where: mask, otherwise: vo), { $0 | $1 }),
                (H.bitwiseXor(va, vb, where: mask, otherwise: vo), { $0 ^ $1 }),
            ]

            for operation in operations {
                var output = ContiguousArray<H.Lane>(repeating: 0, count: lanes)
                var destination = output.mutableSpan
                H.store(operation.vector, to: &destination)
                let expected = (0..<lanes).map { lane in
                    lane < selected ? operation.scalar(a[lane], b[lane]) : other[lane]
                }
                #expect(Array(output) == expected)
            }
        }

        check(SIMDUInt8.self)
        check(SIMDInt32.self)
    }

    @Test("Comparing produces a mask that selects")
    func compareAndSelect() {
        typealias H = SIMDFloat
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
        typealias H = SIMDUInt8
        let lanes = H.laneCount
        for count in [0, 1, lanes - 1, lanes, lanes + 1, 127, 128, 200, Int.max] {
            let mask = H.firstLanes(count: count)
            #expect(H.trueCount(mask) == min(count, lanes))
            #expect(H.firstTrueIndex(mask) == (count == 0 ? -1 : 0))
        }
    }

    @Test("Reductions match the scalar result")
    func reductions() {
        typealias H = SIMDInt32
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
        typealias F = SIMDFloat
        typealias D = SIMDDouble
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
        typealias F = SIMDFloat
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

    @Test("A repeated block fills every 128-bit block with its lanes")
    func repeatingBlock() {
        typealias H = SIMDUInt8
        typealias D = SIMDDouble
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt32
        typealias S = SIMDInt64
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
        typealias H = SIMDDouble
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &* 3) })
        var output = ContiguousArray<UInt8>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        H.store(H.load(from: input.span), to: &destination)

        #expect(output == input)
    }

    @Test("A vector survives an unchecked span store after an unchecked span load")
    func uncheckedSpanLoadStoreRoundTrip() {
        typealias H = SIMDInt32
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { Int32($0) - 2 })
        var output = ContiguousArray<Int32>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        unsafe H.store(H.load(fromUnchecked: input.span), toUnchecked: &destination)

        #expect(output == input)
    }

    @Test("A vector survives aligned span stores after aligned span loads")
    func alignedSpanLoadStoreRoundTrip() {
        typealias H = SIMDUInt32
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
        typealias H = SIMDUInt16
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 5) })
        var output = ContiguousArray<UInt16>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        H.store(H.load(from: input.span.extracting(droppingFirst: lanes)), to: &destination)

        #expect(Array(output) == Array(input.dropFirst(lanes)))
    }

    @Test("A partial span load and store only touch the lanes the span has")
    func partialSpanLoadStore() {
        typealias H = SIMDUInt8
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
        typealias H = SIMDFloat
        let input = ContiguousArray<Float>()
        var output = ContiguousArray<Float>()

        let vector = H.loadFirst(from: input.span)
        var destination = output.mutableSpan
        H.storeFirst(vector, to: &destination)

        #expect(H.allTrue(H.equalTo(vector, H.zero())))
        #expect(output.isEmpty)
    }

    @Test("A widening span load promotes every lane it reads")
    func spanWideningLoad() {
        typealias H = SIMDUInt32
        typealias S = SIMDInt64
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
        typealias H = SIMDDouble
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt16
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDFloat
        var output = OutputSpan<Float>()

        H.append(H.zero(), addingCount: 0, to: &output)
        unsafe H.append(H.zero(), addingCount: 0, toUnchecked: &output)
        let isEmpty = output.isEmpty

        #expect(isEmpty)
    }

    @Test("Aligned appends to an output span continue at aligned addresses")
    func alignedOutputSpanAppend() {
        typealias H = SIMDUInt32
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
        typealias H = SIMDUInt8
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
        typealias H = SIMDUInt16
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

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked span ops trap on a span that is too short")
    func checkedSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount - 1)
            _ = SIMDUInt8.load(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount - 1)
            var destination = output.mutableSpan
            SIMDUInt8.store(SIMDUInt8.zero(), to: &destination)
        }
        await #expect(processExitsWith: .failure) {
            let count = SIMDUInt8.laneCount * 3 - 1
            let input = ContiguousArray<UInt8>(repeating: 0, count: count)
            var v0 = SIMDUInt8.zero()
            var v1 = SIMDUInt8.zero()
            var v2 = SIMDUInt8.zero()
            SIMDUInt8.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        }
        await #expect(processExitsWith: .failure) {
            let count = SIMDUInt8.laneCount * 2 - 1
            var output = ContiguousArray<UInt8>(repeating: 0, count: count)
            var destination = output.mutableSpan
            let zero = SIMDUInt8.zero()
            SIMDUInt8.storeInterleaved2(zero, zero, to: &destination)
        }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt32.laneCount - 1)
            _ = SIMDUInt32.loadWidening(from: input.span)
        }
    }

    @Test("Checked aligned span ops trap on a misaligned span")
    func checkedAlignedSpanOpsTrap() async {
        guard SIMDUInt8.laneCount > 1 else { return }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount * 2)
            _ = SIMDUInt8.loadAligned(from: input.span.extracting(droppingFirst: 1))
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<UInt8>(repeating: 0, count: SIMDUInt8.laneCount * 2)
            output.withUnsafeMutableBufferPointer { buffer in
                let shifted = unsafe UnsafeMutableBufferPointer(rebasing: buffer[1...])
                var destination = unsafe shifted.mutableSpan
                SIMDUInt8.storeAligned(SIMDUInt8.zero(), to: &destination)
            }
        }
    }

    @Test("Checked output span ops trap on too little free capacity or a count out of bounds")
    func checkedOutputSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: SIMDUInt8.laneCount - 1) { output in
                SIMDUInt8.append(SIMDUInt8.zero(), to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: SIMDUInt8.laneCount * 2 - 1) { output in
                let zero = SIMDUInt8.zero()
                SIMDUInt8.appendInterleaved2(zero, zero, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: 2) { output in
                SIMDUInt8.append(SIMDUInt8.zero(), addingCount: 3, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: SIMDUInt8.laneCount * 2) { output in
                let count = SIMDUInt8.laneCount + 1
                SIMDUInt8.append(SIMDUInt8.zero(), addingCount: count, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: 1) { output in
                SIMDUInt8.append(SIMDUInt8.zero(), addingCount: -1, to: &output)
            }
        }
    }

    @Test("Checked lane amount ops trap on an amount outside 0...laneCount")
    func checkedLaneAmountOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideUpLanes(SIMDUInt8.zero(), by: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideUpLanes(SIMDUInt8.zero(), by: SIMDUInt8.laneCount + 1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideDownLanes(SIMDUInt8.zero(), by: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideDownLanes(SIMDUInt8.zero(), by: SIMDUInt8.laneCount + 1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideUpLanes(SIMDUInt8.zero(), by: -1, fillingWith: SIMDUInt8.zero())
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideUpLanes(
                SIMDUInt8.zero(),
                by: SIMDUInt8.laneCount + 1,
                fillingWith: SIMDUInt8.zero()
            )
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideDownLanes(SIMDUInt8.zero(), by: -1, fillingWith: SIMDUInt8.zero())
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.slideDownLanes(
                SIMDUInt8.zero(),
                by: SIMDUInt8.laneCount + 1,
                fillingWith: SIMDUInt8.zero()
            )
        }
    }

    @Test("Checked aligned appends trap on an output span that continues misaligned")
    func checkedAlignedOutputSpanAppendTraps() async {
        guard SIMDUInt8.laneCount > 1 else { return }
        await #expect(processExitsWith: .failure) {
            let lanes = SIMDUInt8.laneCount
            let buffer =
                unsafe UnsafeMutableRawBufferPointer
                .allocate(byteCount: lanes * 2, alignment: lanes)
                .bindMemory(to: UInt8.self)
            unsafe buffer.initialize(repeating: 0)
            var output = unsafe OutputSpan(buffer: buffer, initializedCount: 1)
            SIMDUInt8.appendAligned(SIMDUInt8.zero(), to: &output)
        }
    }
    #endif
}
