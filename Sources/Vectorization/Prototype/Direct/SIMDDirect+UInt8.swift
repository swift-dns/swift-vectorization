public import CVectorizationOps

extension UInt8: SIMDDirectIntegerLane {
    public typealias RawVector = cvectorization_ops_raw_vector_u8
    public typealias RawMask = cvectorization_ops_raw_mask_u8

    @export(implementation) @inline(always)
    public static var _laneCount: Int { Int(cvectorization_ops_lane_count_u8()) }

    @export(implementation) @inline(always)
    public static func _zero() -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: cvectorization_ops_zero_u8())
    }

    @export(implementation) @inline(always)
    public static func _repeating(_ value: UInt8) -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: cvectorization_ops_repeating_u8(value))
    }

    @export(implementation) @inline(always)
    public static func _load(from: UnsafePointer<UInt8>) -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: unsafe cvectorization_ops_load_u8(from))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func _load(from span: Span<UInt8>) -> SIMDDirect<UInt8> {
        precondition(span.count >= _laneCount, "Span has fewer elements than a vector has lanes")
        return unsafe _load(fromUnchecked: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func _load(fromUnchecked span: Span<UInt8>) -> SIMDDirect<UInt8> {
        assert(span.count >= _laneCount, "Span has fewer elements than a vector has lanes")
        return span.withUnsafeBufferPointer {
            SIMDDirect<UInt8>(
                raw: unsafe cvectorization_ops_load_u8($0.baseAddress.unsafelyUnwrapped)
            )
        }
    }

    @export(implementation) @inline(always)
    public static func _store(_ a: SIMDDirect<UInt8>, to: UnsafeMutablePointer<UInt8>) {
        unsafe cvectorization_ops_store_u8(a.raw, to)
    }

    @export(implementation) @inline(always)
    public static func _adding(_ a: SIMDDirect<UInt8>, _ b: SIMDDirect<UInt8>) -> SIMDDirect<UInt8>
    {
        SIMDDirect<UInt8>(raw: cvectorization_ops_adding_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _multiplyAdding(
        _ a: SIMDDirect<UInt8>,
        _ b: SIMDDirect<UInt8>,
        _ c: SIMDDirect<UInt8>
    ) -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: cvectorization_ops_multiply_adding_u8(a.raw, b.raw, c.raw))
    }

    @export(implementation) @inline(always)
    public static func _bitwiseXor(
        _ a: SIMDDirect<UInt8>,
        _ b: SIMDDirect<UInt8>
    ) -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: cvectorization_ops_bitwise_xor_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _equalTo(
        _ a: SIMDDirect<UInt8>,
        _ b: SIMDDirect<UInt8>
    ) -> SIMDDirect<UInt8>.Mask {
        SIMDDirect<UInt8>.Mask(raw: cvectorization_ops_equal_to_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _lessThan(
        _ a: SIMDDirect<UInt8>,
        _ b: SIMDDirect<UInt8>
    ) -> SIMDDirect<UInt8>.Mask {
        SIMDDirect<UInt8>.Mask(raw: cvectorization_ops_less_than_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _selectingOrZero(
        _ mask: SIMDDirect<UInt8>.Mask,
        _ a: SIMDDirect<UInt8>
    ) -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: cvectorization_ops_selecting_or_zero_u8(mask.raw, a.raw))
    }

    @export(implementation) @inline(always)
    public static func _firstLanes(count: Int) -> SIMDDirect<UInt8>.Mask {
        SIMDDirect<UInt8>.Mask(raw: cvectorization_ops_first_lanes_u8(count))
    }

    @export(implementation) @inline(always)
    public static func _trueCount(_ mask: SIMDDirect<UInt8>.Mask) -> Int {
        Int(cvectorization_ops_true_count_u8(mask.raw))
    }

    @export(implementation) @inline(always)
    public static func _sum(_ a: SIMDDirect<UInt8>) -> UInt8 {
        cvectorization_ops_sum_u8(a.raw)
    }

    @export(implementation) @inline(always)
    public static func _slideUpLanes(_ a: SIMDDirect<UInt8>, by lanes: Int) -> SIMDDirect<UInt8> {
        precondition(
            lanes >= 0 && lanes <= _laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return unsafe _slideUpLanes(a, byUnchecked: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func _slideUpLanes(
        _ a: SIMDDirect<UInt8>,
        byUnchecked lanes: Int
    ) -> SIMDDirect<UInt8> {
        assert(
            lanes >= 0 && lanes <= _laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return SIMDDirect<UInt8>(raw: cvectorization_ops_slide_up_lanes_u8(a.raw, lanes))
    }

    @export(implementation) @inline(always)
    public static func _shiftedLeft(_ a: SIMDDirect<UInt8>, by bits: Int) -> SIMDDirect<UInt8> {
        SIMDDirect<UInt8>(raw: cvectorization_ops_shifted_left_u8(a.raw, Int32(clamping: bits)))
    }
}
