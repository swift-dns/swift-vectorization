import Testing
import Vectorization

@Suite("Single-vector demotions")
struct DemotionTests {
    static func edges<Lane: FixedWidthInteger>(_ type: Lane.Type) -> [Lane] {
        var values: [Lane] = [0, 1, 2, ~0, .max, .min, .max / 2, .max / 2 + 1]
        for bits in 1..<Lane.bitWidth {
            let power: Lane = 1 << bits
            values += [power, power &- 1, power &+ 1, 0 &- power, 0 &- power &- 1, 0 &- power &+ 1]
        }
        return values
    }

    static func demoted<Source: FixedWidthInteger, Result: FixedWidthInteger>(
        _ lane: Source,
        to result: Result.Type,
        shiftedRightBy bits: Int,
        rounding: Bool
    ) -> Result {
        var value = lane >> bits
        if rounding && bits > 0 {
            value += (lane >> (bits - 1)) & 1
        }
        return Result(clamping: value)
    }

    func verify<
        Source: SIMDElement & FixedWidthInteger,
        Result: SIMDElement & FixedWidthInteger,
        Narrow
    >(
        _ source: Source.Type,
        _ result: Result.Type,
        store: (Narrow, inout MutableSpan<Result>) -> Void,
        plain: (SIMD<Source>) -> Narrow,
        shifted: (SIMD<Source>, Int) -> Narrow,
        rounded: (SIMD<Source>, Int) -> Narrow
    ) {
        let edges = Self.edges(Source.self)
        let shifts = Set([
            0, 1, 2, Result.bitWidth - 1, Result.bitWidth, Result.bitWidth + 1,
            Source.bitWidth - 1,
        ]).filter { $0 < Source.bitWidth }
        func lanes(_ narrow: Narrow) -> [Result] {
            var output = ContiguousArray<Result>(repeating: 0, count: SIMD<Source>.laneCount)
            var destination = output.mutableSpan
            store(narrow, &destination)
            return Array(output)
        }
        for start in edges.indices {
            let input = ContiguousArray(
                (0..<SIMD<Source>.laneCount).map { edges[(start + $0) % edges.count] }
            )
            let vector = SIMD<Source>.load(from: input.span)
            let name = "\(Source.self) to \(Result.self)"
            #expect(
                lanes(plain(vector))
                    == input.map {
                        Self.demoted($0, to: Result.self, shiftedRightBy: 0, rounding: false)
                    },
                "\(name)"
            )
            for shift in shifts {
                for isRounding in [false, true] {
                    let got = lanes(isRounding ? rounded(vector, shift) : shifted(vector, shift))
                    let want = input.map {
                        Self.demoted(
                            $0,
                            to: Result.self,
                            shiftedRightBy: shift,
                            rounding: isRounding
                        )
                    }
                    #expect(got == want, "\(name) by \(shift), rounding \(isRounding)")
                }
            }
        }
    }

    @Test("Demoting to half the lane width saturates, with and without a shift")
    func half() {
        verify(
            UInt16.self,
            Int8.self,
            store: { SIMD<Int8>.store($0, to: &$1) },
            plain: { SIMD<Int8>.halfVector(clamping: $0) },
            shifted: { SIMD<Int8>.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<Int8>.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int16.self,
            UInt8.self,
            store: { SIMD<UInt8>.store($0, to: &$1) },
            plain: { SIMD<UInt8>.halfVector(clamping: $0) },
            shifted: { SIMD<UInt8>.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<UInt8>.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int32.self,
            UInt16.self,
            store: { SIMD<UInt16>.store($0, to: &$1) },
            plain: { SIMD<UInt16>.halfVector(clamping: $0) },
            shifted: { SIMD<UInt16>.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<UInt16>.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            UInt64.self,
            Int32.self,
            store: { SIMD<Int32>.store($0, to: &$1) },
            plain: { SIMD<Int32>.halfVector(clamping: $0) },
            shifted: { SIMD<Int32>.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<Int32>.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int64.self,
            UInt32.self,
            store: { SIMD<UInt32>.store($0, to: &$1) },
            plain: { SIMD<UInt32>.halfVector(clamping: $0) },
            shifted: { SIMD<UInt32>.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<UInt32>.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
    }

    @Test("Demoting to a quarter of the lane width saturates, with and without a shift")
    func quarter() {
        verify(
            UInt32.self,
            Int8.self,
            store: { SIMD<Int8>.store($0, to: &$1) },
            plain: { SIMD<Int8>.quarterVector(clamping: $0) },
            shifted: { SIMD<Int8>.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<Int8>.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int32.self,
            UInt8.self,
            store: { SIMD<UInt8>.store($0, to: &$1) },
            plain: { SIMD<UInt8>.quarterVector(clamping: $0) },
            shifted: { SIMD<UInt8>.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<UInt8>.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int64.self,
            UInt16.self,
            store: { SIMD<UInt16>.store($0, to: &$1) },
            plain: { SIMD<UInt16>.quarterVector(clamping: $0) },
            shifted: { SIMD<UInt16>.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<UInt16>.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            UInt64.self,
            Int16.self,
            store: { SIMD<Int16>.store($0, to: &$1) },
            plain: { SIMD<Int16>.quarterVector(clamping: $0) },
            shifted: { SIMD<Int16>.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<Int16>.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
    }

    @Test("Demoting to an eighth of the lane width saturates, with and without a shift")
    func eighth() {
        verify(
            UInt64.self,
            Int8.self,
            store: { SIMD<Int8>.store($0, to: &$1) },
            plain: { SIMD<Int8>.eighthVector(clamping: $0) },
            shifted: { SIMD<Int8>.eighthVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<Int8>.eighthVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int64.self,
            UInt8.self,
            store: { SIMD<UInt8>.store($0, to: &$1) },
            plain: { SIMD<UInt8>.eighthVector(clamping: $0) },
            shifted: { SIMD<UInt8>.eighthVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<UInt8>.eighthVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            Int64.self,
            Int8.self,
            store: { SIMD<Int8>.store($0, to: &$1) },
            plain: { SIMD<Int8>.eighthVector(clamping: $0) },
            shifted: { SIMD<Int8>.eighthVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMD<Int8>.eighthVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked shifting demotions trap on a shift of a whole lane or more")
    func checkedShiftTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMD<Int8>.halfVector(clamping: SIMD<Int16>.zero(), shiftedRightBy: 16)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<Int8>.quarterVector(clamping: SIMD<Int32>.zero(), roundingShiftedRightBy: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMD<UInt8>.eighthVector(clamping: SIMD<UInt64>.zero(), shiftedRightBy: 64)
        }
    }
    #endif
}
