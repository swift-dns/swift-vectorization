#if PROTOTYPE_DIRECT_CONCRETE && PROTOTYPE_DIRECT_CONCRETE_INIT
public import CVectorizationOps

extension SIMDDirect where Lane == UInt8 {
    @export(implementation) @inline(always)
    public init(raw: cvectorization_ops_raw_vector_u8) {
        self.raw = raw
    }
}

extension SIMDDirect.Mask where Lane == UInt8 {
    @export(implementation) @inline(always)
    public init(raw: cvectorization_ops_raw_mask_u8) {
        self.raw = raw
    }
}

extension SIMDDirect where Lane == Int32 {
    @export(implementation) @inline(always)
    public init(raw: cvectorization_ops_raw_vector_i32) {
        self.raw = raw
    }
}

extension SIMDDirect.Mask where Lane == Int32 {
    @export(implementation) @inline(always)
    public init(raw: cvectorization_ops_raw_mask_i32) {
        self.raw = raw
    }
}

extension SIMDDirect where Lane == Float {
    @export(implementation) @inline(always)
    public init(raw: cvectorization_ops_vector_f32) {
        self.raw = raw
    }
}

extension SIMDDirect.Mask where Lane == Float {
    @export(implementation) @inline(always)
    public init(raw: cvectorization_ops_raw_mask_f32) {
        self.raw = raw
    }
}
#endif
