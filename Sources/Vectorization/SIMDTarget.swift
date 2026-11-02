internal import CVectorizationOps

/// Runtime information about the SIMD target this package was compiled for.
///
/// The ops are compiled for a static target, the one the compiler flags select, rather than one
/// chosen at run time. On arm64 that is NEON, which is baseline. On x86_64 the baseline is SSE2,
/// or SSSE3 on Apple platforms and Android. SSE4 and AVX2 also need AES and PCLMUL, as in
/// `-Xcc -march=x86-64-v3 -Xcc -maes -Xcc -mpclmul` for AVX2's 32-byte vectors, and AVX-512 flags
/// give 64-byte vectors.
public enum SIMDTarget: SendableMetatype {
    /// The name of the target the ops were compiled for, such as `NEON` or `AVX2`.
    public static var targetName: String {
        unsafe String(cString: cvectorization_ops_target_name())
    }

    /// Whether the target only emulates vectors, in which case scalar code is faster.
    public static var isEmulated: Bool {
        cvectorization_ops_is_emulated()
    }
}

@available(*, unavailable)
extension SIMDTarget: Sendable {}
