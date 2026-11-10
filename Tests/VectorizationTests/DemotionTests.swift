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

    func verify<Source: SIMDElement, Result: SIMDElement, Narrow>(
        _ source: Source.Type,
        _ result: Result.Type,
        store: (Narrow, inout MutableSpan<Result.Lane>) -> Void,
        plain: (Source.Vector) -> Narrow,
        shifted: (Source.Vector, Int) -> Narrow,
        rounded: (Source.Vector, Int) -> Narrow
    ) where Source.Lane: FixedWidthInteger, Result.Lane: FixedWidthInteger {
        let edges = Self.edges(Source.Lane.self)
        let shifts = Set([
            0, 1, 2, Result.Lane.bitWidth - 1, Result.Lane.bitWidth, Result.Lane.bitWidth + 1,
            Source.Lane.bitWidth - 1,
        ]).filter { $0 < Source.Lane.bitWidth }
        func lanes(_ narrow: Narrow) -> [Result.Lane] {
            var output = ContiguousArray<Result.Lane>(repeating: 0, count: Source.laneCount)
            var destination = output.mutableSpan
            store(narrow, &destination)
            return Array(output)
        }
        for start in edges.indices {
            let input = ContiguousArray(
                (0..<Source.laneCount).map { edges[(start + $0) % edges.count] }
            )
            let vector = Source.load(from: input.span)
            let name = "\(Source.Lane.self) to \(Result.Lane.self)"
            #expect(
                lanes(plain(vector))
                    == input.map {
                        Self.demoted($0, to: Result.Lane.self, shiftedRightBy: 0, rounding: false)
                    },
                "\(name)"
            )
            for shift in shifts {
                for isRounding in [false, true] {
                    let got = lanes(isRounding ? rounded(vector, shift) : shifted(vector, shift))
                    let want = input.map {
                        Self.demoted(
                            $0,
                            to: Result.Lane.self,
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
            SIMDUInt16.self,
            SIMDInt8.self,
            store: { SIMDInt8.store($0, to: &$1) },
            plain: { SIMDInt8.halfVector(clamping: $0) },
            shifted: { SIMDInt8.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDInt8.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt16.self,
            SIMDUInt8.self,
            store: { SIMDUInt8.store($0, to: &$1) },
            plain: { SIMDUInt8.halfVector(clamping: $0) },
            shifted: { SIMDUInt8.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDUInt8.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt32.self,
            SIMDUInt16.self,
            store: { SIMDUInt16.store($0, to: &$1) },
            plain: { SIMDUInt16.halfVector(clamping: $0) },
            shifted: { SIMDUInt16.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDUInt16.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDUInt64.self,
            SIMDInt32.self,
            store: { SIMDInt32.store($0, to: &$1) },
            plain: { SIMDInt32.halfVector(clamping: $0) },
            shifted: { SIMDInt32.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDInt32.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt64.self,
            SIMDUInt32.self,
            store: { SIMDUInt32.store($0, to: &$1) },
            plain: { SIMDUInt32.halfVector(clamping: $0) },
            shifted: { SIMDUInt32.halfVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDUInt32.halfVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
    }

    @Test("Demoting to a quarter of the lane width saturates, with and without a shift")
    func quarter() {
        verify(
            SIMDUInt32.self,
            SIMDInt8.self,
            store: { SIMDInt8.store($0, to: &$1) },
            plain: { SIMDInt8.quarterVector(clamping: $0) },
            shifted: { SIMDInt8.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDInt8.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt32.self,
            SIMDUInt8.self,
            store: { SIMDUInt8.store($0, to: &$1) },
            plain: { SIMDUInt8.quarterVector(clamping: $0) },
            shifted: { SIMDUInt8.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDUInt8.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt64.self,
            SIMDUInt16.self,
            store: { SIMDUInt16.store($0, to: &$1) },
            plain: { SIMDUInt16.quarterVector(clamping: $0) },
            shifted: { SIMDUInt16.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDUInt16.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDUInt64.self,
            SIMDInt16.self,
            store: { SIMDInt16.store($0, to: &$1) },
            plain: { SIMDInt16.quarterVector(clamping: $0) },
            shifted: { SIMDInt16.quarterVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDInt16.quarterVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
    }

    @Test("Demoting to an eighth of the lane width saturates, with and without a shift")
    func eighth() {
        verify(
            SIMDUInt64.self,
            SIMDInt8.self,
            store: { SIMDInt8.store($0, to: &$1) },
            plain: { SIMDInt8.eighthVector(clamping: $0) },
            shifted: { SIMDInt8.eighthVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDInt8.eighthVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt64.self,
            SIMDUInt8.self,
            store: { SIMDUInt8.store($0, to: &$1) },
            plain: { SIMDUInt8.eighthVector(clamping: $0) },
            shifted: { SIMDUInt8.eighthVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDUInt8.eighthVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
        verify(
            SIMDInt64.self,
            SIMDInt8.self,
            store: { SIMDInt8.store($0, to: &$1) },
            plain: { SIMDInt8.eighthVector(clamping: $0) },
            shifted: { SIMDInt8.eighthVector(clamping: $0, shiftedRightBy: $1) },
            rounded: { SIMDInt8.eighthVector(clamping: $0, roundingShiftedRightBy: $1) }
        )
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked shifting demotions trap on a shift of a whole lane or more")
    func checkedShiftTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = SIMDInt8.halfVector(clamping: SIMDInt16.zero(), shiftedRightBy: 16)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDInt8.quarterVector(clamping: SIMDInt32.zero(), roundingShiftedRightBy: -1)
        }
        await #expect(processExitsWith: .failure) {
            _ = SIMDUInt8.eighthVector(clamping: SIMDUInt64.zero(), shiftedRightBy: 64)
        }
    }
    #endif
}
