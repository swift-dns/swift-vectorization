/// A 16-bit floating point number with the range of `Float` and 8 bits of precision.
///
/// Its conversions to and from `Float` are those of Highway's `F32FromBF16` and `BF16FromF32`.
public struct BFloat16: Sendable, Hashable {
    /// The bits of the number: the upper 16 bits of the `Float` it equals.
    public var bitPattern: UInt16

    @export(implementation) @inline(always)
    public init(bitPattern: UInt16) {
        self.bitPattern = bitPattern
    }

    /// Creates the `BFloat16` nearest to `value`, rounding ties to even and quieting NaNs.
    @export(implementation) @inline(always)
    public init(_ value: Float) {
        let bits = value.bitPattern
        let isFinite = bits & 0x7FFF_FFFF < 0x7F80_0000
        let roundingIncrement: UInt32 = isFinite ? 0x7FFF + (bits >> 16) & 1 : 0
        let quietBit: UInt32 = bits & 0x7FFF_FFFF > 0x7F80_0000 ? 1 << 6 : 0
        bitPattern = UInt16(truncatingIfNeeded: quietBit | (bits &+ roundingIncrement) >> 16)
    }
}

extension Float {
    /// Creates the `Float` that equals `value`.
    @export(implementation) @inline(always)
    public init(_ value: BFloat16) {
        self.init(bitPattern: UInt32(value.bitPattern) << 16)
    }
}
