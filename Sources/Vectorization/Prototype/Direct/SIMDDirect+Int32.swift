public import CVectorizationOps

extension Int32: SIMDDirectIntegerLane {
    public typealias RawVector = cvectorization_ops_raw_vector_i32
    public typealias RawMask = cvectorization_ops_raw_mask_i32

    @export(implementation) @inline(always)
    public static var _laneCount: Int { Int(cvectorization_ops_lane_count_i32()) }

    @export(implementation) @inline(always)
    public static func _zero() -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: cvectorization_ops_zero_i32())
    }

    @export(implementation) @inline(always)
    public static func _repeating(_ value: Int32) -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: cvectorization_ops_repeating_i32(value))
    }

    @export(implementation) @inline(always)
    public static func _load(from: UnsafePointer<Int32>) -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: unsafe cvectorization_ops_load_i32(from))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func _load(from span: Span<Int32>) -> SIMDDirect<Int32> {
        precondition(span.count >= _laneCount, "Span has fewer elements than a vector has lanes")
        return unsafe _load(fromUnchecked: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func _load(fromUnchecked span: Span<Int32>) -> SIMDDirect<Int32> {
        assert(span.count >= _laneCount, "Span has fewer elements than a vector has lanes")
        return span.withUnsafeBufferPointer {
            SIMDDirect<Int32>(
                raw: unsafe cvectorization_ops_load_i32($0.baseAddress.unsafelyUnwrapped)
            )
        }
    }

    @export(implementation) @inline(always)
    public static func _store(_ a: SIMDDirect<Int32>, to: UnsafeMutablePointer<Int32>) {
        unsafe cvectorization_ops_store_i32(a.raw, to)
    }

    @export(implementation) @inline(always)
    public static func _adding(_ a: SIMDDirect<Int32>, _ b: SIMDDirect<Int32>) -> SIMDDirect<Int32>
    {
        SIMDDirect<Int32>(raw: cvectorization_ops_adding_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _multiplyAdding(
        _ a: SIMDDirect<Int32>,
        _ b: SIMDDirect<Int32>,
        _ c: SIMDDirect<Int32>
    ) -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: cvectorization_ops_multiply_adding_i32(a.raw, b.raw, c.raw))
    }

    @export(implementation) @inline(always)
    public static func _bitwiseXor(
        _ a: SIMDDirect<Int32>,
        _ b: SIMDDirect<Int32>
    ) -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: cvectorization_ops_bitwise_xor_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _equalTo(
        _ a: SIMDDirect<Int32>,
        _ b: SIMDDirect<Int32>
    ) -> SIMDDirect<Int32>.Mask {
        SIMDDirect<Int32>.Mask(raw: cvectorization_ops_equal_to_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _lessThan(
        _ a: SIMDDirect<Int32>,
        _ b: SIMDDirect<Int32>
    ) -> SIMDDirect<Int32>.Mask {
        SIMDDirect<Int32>.Mask(raw: cvectorization_ops_less_than_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _selectingOrZero(
        _ mask: SIMDDirect<Int32>.Mask,
        _ a: SIMDDirect<Int32>
    ) -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: cvectorization_ops_selecting_or_zero_i32(mask.raw, a.raw))
    }

    @export(implementation) @inline(always)
    public static func _firstLanes(count: Int) -> SIMDDirect<Int32>.Mask {
        SIMDDirect<Int32>.Mask(raw: cvectorization_ops_first_lanes_i32(count))
    }

    @export(implementation) @inline(always)
    public static func _trueCount(_ mask: SIMDDirect<Int32>.Mask) -> Int {
        Int(cvectorization_ops_true_count_i32(mask.raw))
    }

    @export(implementation) @inline(always)
    public static func _sum(_ a: SIMDDirect<Int32>) -> Int32 {
        cvectorization_ops_sum_i32(a.raw)
    }

    @export(implementation) @inline(always)
    public static func _slideUpLanes(_ a: SIMDDirect<Int32>, by lanes: Int) -> SIMDDirect<Int32> {
        precondition(
            lanes >= 0 && lanes <= _laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return unsafe _slideUpLanes(a, byUnchecked: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func _slideUpLanes(
        _ a: SIMDDirect<Int32>,
        byUnchecked lanes: Int
    ) -> SIMDDirect<Int32> {
        assert(
            lanes >= 0 && lanes <= _laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return SIMDDirect<Int32>(raw: cvectorization_ops_slide_up_lanes_i32(a.raw, lanes))
    }

    @export(implementation) @inline(always)
    public static func _shiftedLeft(_ a: SIMDDirect<Int32>, by bits: Int) -> SIMDDirect<Int32> {
        SIMDDirect<Int32>(raw: cvectorization_ops_shifted_left_i32(a.raw, Int32(clamping: bits)))
    }
}
