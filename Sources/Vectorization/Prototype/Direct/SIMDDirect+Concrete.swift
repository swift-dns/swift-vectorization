#if PROTOTYPE_DIRECT_CONCRETE
public import CVectorizationOps

extension SIMDDirect where Lane == UInt8 {
    @export(implementation) @inline(always)
    public static var laneCount: Int { Int(cvectorization_ops_lane_count_u8()) }

    @export(implementation) @inline(always)
    public static func zero() -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_zero_u8())
    }

    @export(implementation) @inline(always)
    public static func repeating(_ value: UInt8) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_repeating_u8(value))
    }

    @export(implementation) @inline(always)
    public static func load(from: UnsafePointer<UInt8>) -> SIMDDirect {
        SIMDDirect(raw: unsafe cvectorization_ops_load_u8(from))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func load(from span: Span<UInt8>) -> SIMDDirect {
        precondition(span.count >= laneCount, "Span has fewer elements than a vector has lanes")
        return unsafe load(fromUnchecked: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func load(fromUnchecked span: Span<UInt8>) -> SIMDDirect {
        assert(span.count >= laneCount, "Span has fewer elements than a vector has lanes")
        return span.withUnsafeBufferPointer {
            SIMDDirect(raw: unsafe cvectorization_ops_load_u8($0.baseAddress.unsafelyUnwrapped))
        }
    }

    @export(implementation) @inline(always)
    public static func store(_ a: SIMDDirect, to: UnsafeMutablePointer<UInt8>) {
        unsafe cvectorization_ops_store_u8(a.raw, to)
    }

    @export(implementation) @inline(always)
    public static func adding(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_adding_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func multiplyAdding(
        _ a: SIMDDirect,
        _ b: SIMDDirect,
        _ c: SIMDDirect
    ) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_multiply_adding_u8(a.raw, b.raw, c.raw))
    }

    @export(implementation) @inline(always)
    public static func bitwiseXor(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_bitwise_xor_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func equalTo(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Mask(raw: cvectorization_ops_equal_to_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func lessThan(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Mask(raw: cvectorization_ops_less_than_u8(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func selectingOrZero(_ mask: Mask, _ a: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_selecting_or_zero_u8(mask.raw, a.raw))
    }

    @export(implementation) @inline(always)
    public static func firstLanes(count: Int) -> Mask {
        Mask(raw: cvectorization_ops_first_lanes_u8(count))
    }

    @export(implementation) @inline(always)
    public static func trueCount(_ mask: Mask) -> Int {
        Int(cvectorization_ops_true_count_u8(mask.raw))
    }

    @export(implementation) @inline(always)
    public static func sum(_ a: SIMDDirect) -> UInt8 {
        cvectorization_ops_sum_u8(a.raw)
    }

    @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, by lanes: Int) -> SIMDDirect {
        precondition(
            lanes >= 0 && lanes <= laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return unsafe slideUpLanes(a, byUnchecked: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, byUnchecked lanes: Int) -> SIMDDirect {
        assert(
            lanes >= 0 && lanes <= laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return SIMDDirect(raw: cvectorization_ops_slide_up_lanes_u8(a.raw, lanes))
    }

    @export(implementation) @inline(always)
    public static func shiftedLeft(_ a: SIMDDirect, by bits: Int) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_shifted_left_u8(a.raw, Int32(clamping: bits)))
    }
}

extension SIMDDirect where Lane == Int32 {
    @export(implementation) @inline(always)
    public static var laneCount: Int { Int(cvectorization_ops_lane_count_i32()) }

    @export(implementation) @inline(always)
    public static func zero() -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_zero_i32())
    }

    @export(implementation) @inline(always)
    public static func repeating(_ value: Int32) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_repeating_i32(value))
    }

    @export(implementation) @inline(always)
    public static func load(from: UnsafePointer<Int32>) -> SIMDDirect {
        SIMDDirect(raw: unsafe cvectorization_ops_load_i32(from))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func load(from span: Span<Int32>) -> SIMDDirect {
        precondition(span.count >= laneCount, "Span has fewer elements than a vector has lanes")
        return unsafe load(fromUnchecked: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func load(fromUnchecked span: Span<Int32>) -> SIMDDirect {
        assert(span.count >= laneCount, "Span has fewer elements than a vector has lanes")
        return span.withUnsafeBufferPointer {
            SIMDDirect(raw: unsafe cvectorization_ops_load_i32($0.baseAddress.unsafelyUnwrapped))
        }
    }

    @export(implementation) @inline(always)
    public static func store(_ a: SIMDDirect, to: UnsafeMutablePointer<Int32>) {
        unsafe cvectorization_ops_store_i32(a.raw, to)
    }

    @export(implementation) @inline(always)
    public static func adding(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_adding_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func multiplyAdding(
        _ a: SIMDDirect,
        _ b: SIMDDirect,
        _ c: SIMDDirect
    ) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_multiply_adding_i32(a.raw, b.raw, c.raw))
    }

    @export(implementation) @inline(always)
    public static func bitwiseXor(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_bitwise_xor_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func equalTo(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Mask(raw: cvectorization_ops_equal_to_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func lessThan(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Mask(raw: cvectorization_ops_less_than_i32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func selectingOrZero(_ mask: Mask, _ a: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_selecting_or_zero_i32(mask.raw, a.raw))
    }

    @export(implementation) @inline(always)
    public static func firstLanes(count: Int) -> Mask {
        Mask(raw: cvectorization_ops_first_lanes_i32(count))
    }

    @export(implementation) @inline(always)
    public static func trueCount(_ mask: Mask) -> Int {
        Int(cvectorization_ops_true_count_i32(mask.raw))
    }

    @export(implementation) @inline(always)
    public static func sum(_ a: SIMDDirect) -> Int32 {
        cvectorization_ops_sum_i32(a.raw)
    }

    @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, by lanes: Int) -> SIMDDirect {
        precondition(
            lanes >= 0 && lanes <= laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return unsafe slideUpLanes(a, byUnchecked: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, byUnchecked lanes: Int) -> SIMDDirect {
        assert(
            lanes >= 0 && lanes <= laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return SIMDDirect(raw: cvectorization_ops_slide_up_lanes_i32(a.raw, lanes))
    }

    @export(implementation) @inline(always)
    public static func shiftedLeft(_ a: SIMDDirect, by bits: Int) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_shifted_left_i32(a.raw, Int32(clamping: bits)))
    }
}

extension SIMDDirect where Lane == Float {
    @export(implementation) @inline(always)
    public static var laneCount: Int { Int(cvectorization_ops_lane_count_f32()) }

    @export(implementation) @inline(always)
    public static func zero() -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_zero_f32())
    }

    @export(implementation) @inline(always)
    public static func repeating(_ value: Float) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_repeating_f32(value))
    }

    @export(implementation) @inline(always)
    public static func load(from: UnsafePointer<Float>) -> SIMDDirect {
        SIMDDirect(raw: unsafe cvectorization_ops_load_f32(from))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func load(from span: Span<Float>) -> SIMDDirect {
        precondition(span.count >= laneCount, "Span has fewer elements than a vector has lanes")
        return unsafe load(fromUnchecked: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func load(fromUnchecked span: Span<Float>) -> SIMDDirect {
        assert(span.count >= laneCount, "Span has fewer elements than a vector has lanes")
        return span.withUnsafeBufferPointer {
            SIMDDirect(raw: unsafe cvectorization_ops_load_f32($0.baseAddress.unsafelyUnwrapped))
        }
    }

    @export(implementation) @inline(always)
    public static func store(_ a: SIMDDirect, to: UnsafeMutablePointer<Float>) {
        unsafe cvectorization_ops_store_f32(a.raw, to)
    }

    @export(implementation) @inline(always)
    public static func adding(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_adding_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func multiplyAdding(
        _ a: SIMDDirect,
        _ b: SIMDDirect,
        _ c: SIMDDirect
    ) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_multiply_adding_f32(a.raw, b.raw, c.raw))
    }

    @export(implementation) @inline(always)
    public static func bitwiseXor(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_bitwise_xor_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func equalTo(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Mask(raw: cvectorization_ops_equal_to_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func lessThan(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Mask(raw: cvectorization_ops_less_than_f32(a.raw, b.raw))
    }

    @export(implementation) @inline(always)
    public static func selectingOrZero(_ mask: Mask, _ a: SIMDDirect) -> SIMDDirect {
        SIMDDirect(raw: cvectorization_ops_selecting_or_zero_f32(mask.raw, a.raw))
    }

    @export(implementation) @inline(always)
    public static func firstLanes(count: Int) -> Mask {
        Mask(raw: cvectorization_ops_first_lanes_f32(count))
    }

    @export(implementation) @inline(always)
    public static func trueCount(_ mask: Mask) -> Int {
        Int(cvectorization_ops_true_count_f32(mask.raw))
    }

    @export(implementation) @inline(always)
    public static func sum(_ a: SIMDDirect) -> Float {
        cvectorization_ops_sum_f32(a.raw)
    }

    @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, by lanes: Int) -> SIMDDirect {
        precondition(
            lanes >= 0 && lanes <= laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return unsafe slideUpLanes(a, byUnchecked: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, byUnchecked lanes: Int) -> SIMDDirect {
        assert(
            lanes >= 0 && lanes <= laneCount,
            "Lane amount is negative or more than a vector has lanes"
        )
        return SIMDDirect(raw: cvectorization_ops_slide_up_lanes_f32(a.raw, lanes))
    }
}
#endif
