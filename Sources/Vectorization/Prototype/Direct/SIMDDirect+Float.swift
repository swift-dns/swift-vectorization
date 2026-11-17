public import CVectorizationOps

extension Float: SIMDDirectLane {
    public typealias RawVector = cvectorization_ops_vector_f32
    public typealias RawMask = cvectorization_ops_raw_mask_f32

    @export(implementation) @inline(always)
    public static var _laneCount: Int { Int(cvectorization_ops_lane_count_f32()) }

    @export(implementation) @inline(always)
    public static func _zero() -> SIMDDirect<Float> {
        SIMDDirect<Float>(raw: cvectorization_ops_zero_f32())
    }

    @export(implementation) @inline(always)
    public static func _repeating(_ value: Float) -> SIMDDirect<Float> {
        SIMDDirect<Float>(raw: cvectorization_ops_repeating_f32(value))
    }

    @export(implementation) @inline(always)
    public static func _load(from: UnsafePointer<Float>) -> SIMDDirect<Float> {
        SIMDDirect<Float>(raw: unsafe cvectorization_ops_load_f32(from))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func _load(from span: Span<Float>) -> SIMDDirect<Float> {
        precondition(span.count >= _laneCount, "Span has fewer elements than a vector has lanes")
        return unsafe _load(fromUnchecked: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func _load(fromUnchecked span: Span<Float>) -> SIMDDirect<Float> {
        assert(span.count >= _laneCount, "Span has fewer elements than a vector has lanes")
        return span.withUnsafeBufferPointer {
            SIMDDirect<Float>(
                raw: unsafe cvectorization_ops_load_f32($0.baseAddress.unsafelyUnwrapped)
            )
        }
    }

    @export(implementation) @inline(always)
    public static func _store(_ a: SIMDDirect<Float>, to: UnsafeMutablePointer<Float>) {
        unsafe cvectorization_ops_store_f32(a.raw, to)
    }

    @export(implementation) @inline(always)
    public static func _adding(_ a: SIMDDirect<Float>, _ b: SIMDDirect<Float>) -> SIMDDirect<Float>
    {
        SIMDDirect<Float>(raw: cvectorization_ops_adding_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _multiplyAdding(
        _ a: SIMDDirect<Float>,
        _ b: SIMDDirect<Float>,
        _ c: SIMDDirect<Float>
    ) -> SIMDDirect<Float> {
        SIMDDirect<Float>(raw: cvectorization_ops_multiply_adding_f32(a.raw, b.raw, c.raw))
    }

    @export(implementation) @inline(always)
    public static func _bitwiseXor(
        _ a: SIMDDirect<Float>,
        _ b: SIMDDirect<Float>
    ) -> SIMDDirect<Float> {
        SIMDDirect<Float>(raw: cvectorization_ops_bitwise_xor_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _equalTo(
        _ a: SIMDDirect<Float>,
        _ b: SIMDDirect<Float>
    ) -> SIMDDirect<Float>.Mask {
        SIMDDirect<Float>.Mask(raw: cvectorization_ops_equal_to_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _lessThan(
        _ a: SIMDDirect<Float>,
        _ b: SIMDDirect<Float>
    ) -> SIMDDirect<Float>.Mask {
        SIMDDirect<Float>.Mask(raw: cvectorization_ops_less_than_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func _selectingOrZero(
        _ mask: SIMDDirect<Float>.Mask,
        _ a: SIMDDirect<Float>
    ) -> SIMDDirect<Float> {
        SIMDDirect<Float>(raw: cvectorization_ops_selecting_or_zero_f32(mask.raw, a.raw))
    }

    @export(implementation) @inline(always)
    public static func _firstLanes(count: Int) -> SIMDDirect<Float>.Mask {
        SIMDDirect<Float>.Mask(raw: cvectorization_ops_first_lanes_f32(count))
    }

    @export(implementation) @inline(always)
    public static func _trueCount(_ mask: SIMDDirect<Float>.Mask) -> Int {
        Int(cvectorization_ops_true_count_f32(mask.raw))
    }

    @export(implementation) @inline(always)
    public static func _sum(_ a: SIMDDirect<Float>) -> Float {
        cvectorization_ops_sum_f32(a.raw)
    }

    @export(implementation) @inline(always)
    public static func _slideUpLanes(_ a: SIMDDirect<Float>, by lanes: Int) -> SIMDDirect<Float> {
        precondition(
            lanes >= 0 && lanes <= _laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return unsafe _slideUpLanes(a, byUnchecked: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func _slideUpLanes(
        _ a: SIMDDirect<Float>,
        byUnchecked lanes: Int
    ) -> SIMDDirect<Float> {
        assert(
            lanes >= 0 && lanes <= _laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return SIMDDirect<Float>(raw: cvectorization_ops_slide_up_lanes_f32(a.raw, lanes))
    }
}
