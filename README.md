<p>
    <a href="https://github.com/swift-dns/swift-vectorization/actions/workflows/unit-tests.yml">
        <img
            src="https://img.shields.io/github/actions/workflow/status/swift-dns/swift-vectorization/unit-tests.yml?event=push&style=plastic&logo=github&label=unit-tests&logoColor=%23ccc"
            alt="Unit Tests CI"
        >
    </a>
    <a href="https://swift.org">
        <img
            src="https://design.vapor.codes/images/swift63up.svg"
            alt="Swift 6.3+"
        >
    </a>
</p>

# swift-vectorization

[highway](https://github.com/google/highway)'s portable SIMD ops for Swift, with no C++ to configure.

Supports `Darwin` (`Apple` platforms), `Linux` (including `Android`), `Windows`, `FreeBSD`, `OpenBSD`[^1], `WASI`, embedded, and more.

[^1]: Swift support for `OpenBSD` is a work-in-progress. This library doesn't have CI for `OpenBSD` yet, so things can be flaky.

## Using swift-vectorization

Add the dependency to the target that wants it. No settings are needed, neither in your package nor in the packages that depend on yours:

```diff
dependencies: [
+    .package(url: "https://github.com/swift-dns/swift-vectorization.git", exact: "1.0.0-alpha.8")
],
targets: [
    .target(
        name: "MyLibrary",
+        dependencies: [.product(name: "Vectorization", package: "swift-vectorization")]
    )
]
```

Each element type has its own namespace of ops, such as `SIMDUInt8`, and `SIMDElement` lets a kernel be written once for all of them except `SIMDBFloat16`:

```swift
import Vectorization

func count(of needle: UInt8, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
    let target = SIMDUInt8.repeating(needle)
    var count = 0
    var index = 0
    while index + SIMDUInt8.laneCount <= bytes.count {
        let vector = SIMDUInt8.load(from: bytes.baseAddress! + index)
        count += SIMDUInt8.trueCount(SIMDUInt8.equalTo(vector, target))
        index += SIMDUInt8.laneCount
    }
    return bytes[index...].reduce(count) { $0 + ($1 == needle ? 1 : 0) }
}
```

## Which target you get

The ops are compiled for highway's static target: the one highway picks for the same compiler flags,
found by highway's own target detection. So `laneCount` is what highway's `Lanes(ScalableTag<T>())`
returns under static dispatch, and `Vector.SIMDType` is as wide as the target's vectors.

| Platform | Target                               | Bytes | Description                                                                                                                 |
| -------- | ------------------------------------ | ----- | --------------------------------------------------------------------------------------------------------------------------- |
| arm64    | NEON, NEON_WITHOUT_AES, NEON_BF16    | 16    | The baseline: NEON on Apple platforms, elsewhere NEON_WITHOUT_AES unless `-march` enables AES.                              |
| arm64    | SVE2_128                             | 16    | With `-Xcc -march=armv9-a+bf16+i8mm -Xcc -msve-vector-bits=128`.                                                            |
| x86_64   | SSE2, SSSE3, SSE4                    | 16    | SSE2 is the baseline, SSSE3 on Apple platforms and Android. SSE4 needs `-Xcc -march=x86-64-v2 -Xcc -maes -Xcc -mpclmul`.    |
| x86_64   | AVX2                                 | 32    | With `-Xcc -march=x86-64-v3 -Xcc -maes -Xcc -mpclmul`, or a CPU such as `-Xcc -march=skylake`.                              |
| x86_64   | AVX3, AVX3_DL, AVX3_ZEN4, AVX3_SPR   | 64    | With AVX-512 flags, such as `-Xcc -march=skylake-avx512` or `-Xcc -march=icelake-server`.                                   |
| Others   | EMU128, or WASM, PPC8, Z14 and so on | 16    | Portable C, which the compiler lowers to the SIMD the platform has, or to scalar code. `targetName` names highway's target. |

Like highway, SSE4 and AVX2 also need AES and PCLMUL, so `-Xcc -march=x86-64-v3` alone gives SSSE3,
and SVE2_128 needs BF16 and I8MM, without which the build fails with an error that names them.
A build for which highway would pick a target the port does not support, such as SVE sized at run
time, AVX10_2 or WASM_EMU256, fails with an error that names the flag to use instead.

Swift's own code generation does not see `-msve-vector-bits`, so SVE2_128 builds should also pass
`-Xswiftc -Xllvm -Xswiftc -aarch64-sve-vector-bits-min=128` and
`-Xswiftc -Xllvm -Xswiftc -aarch64-sve-vector-bits-max=128`. Without them the ops are still right,
but some of them spend extra instructions on vector lengths the build cannot have.

Highway can also pick the target at run time with dynamic dispatch. Swift cannot compile one function
for several CPU levels, so the port matches highway's static dispatch only.

`SIMDTarget.targetName` reports highway's name for the target, and `SIMDTarget.isEmulated` is true on
EMU128, as highway's is, where scalar code is faster.

`SIMDTarget` also has highway's capability macros as constants: `memoryOpsMightFault` is
`HWY_MEM_OPS_MIGHT_FAULT`, `hasNativeFusedMultiplyAdd` is `HWY_NATIVE_FMA`, `hasNativeMasking` is
`HWY_NATIVE_MASK`, `hasNativeBFloat16DotProduct` is `HWY_NATIVE_DOT_BF16`,
`hasNativeWholeInterleave` is `HWY_NATIVE_INTERLEAVE_WHOLE`, `hasNativeStoreFirst` is
`HWY_NATIVE_STORE_N`, `hasNative64BitMultiply` is `HWY_NATIVE_MUL64`, `hasNativeFloat16Arithmetic`
is `HWY_HAVE_FLOAT16` and `registerCount` is `HWY_REGISTERS`. They describe the port's own ops, so
on the portable C targets, whose ops follow highway's EMU128, they take EMU128's values:
`hasNativeFusedMultiplyAdd` is false on PPC8 and Z14, for example, where highway's own ops fuse.

`SIMDTarget.target` is the target the ops were compiled for, as a `SIMDTargetSet`, which has
highway's bit and name for each of highway's targets. `SIMDTarget.supportedTargets` is highway's
`SupportedTargets()`: it mirrors highway's detection on x86 and arm, and on other architectures,
where highway also detects the CPU's targets, it reports the compiled baseline.
`SIMDTarget.isSupported` is whether it contains `SIMDTarget.target`. Like highway's, the detection
reports what the CPU advertises, so under Rosetta, which advertises no AVX, an AVX2 build reports
itself unsupported although it runs.

## How it relates to highway

Every op reproduces what highway does on the same target, down to NaN payloads and the results of
out-of-range inputs, so the ops behave like highway's. `HighwayReference/` holds a copy of highway
and generated tests that compare every op with highway's, lane for lane, on NEON, NEON_WITHOUT_AES,
SVE2_128, SSE2, SSSE3, SSE4, AVX2, the AVX-512 targets under Intel's SDE, and highway's EMU128.

When an op meets two NaNs with different payloads, as in an addition, a multiplication, a sum, or a
minimum or maximum on SVE, which payload comes out is up to the compiler, in highway as in the port.

A mask made from a vector whose lanes are not all zeros or all ones, with `mask(from:)` or
`Mask(raw:)`, behaves in every op as highway's `MaskFromVec` of the same vector does on the same
target, which highway leaves to the target. On NEON, SSE2 through AVX2 and EMU128 each op reads the
bits of the mask that highway's op reads, on the AVX-512 targets only the sign bit of each lane
counts, and on SVE2_128 a lane is true when it is not zero, compared as a number for `SIMDFloat`,
`SIMDDouble` and `SIMDFloat16`, so that `-0.0` is false there.

On the targets without a carry-less multiply instruction, SSE2, SSSE3, NEON_WITHOUT_AES, SVE2_128
without SVE2-AES, and EMU128, highway's `CLMulLower` and `CLMulUpper` return a wrong upper 64 bits
when both operands have one of the bit groups `0x1111111111111111 << k` (k = 0...3) fully set, as
`~0` does. So do the port's `carrylessMultiplyingLower` and `carrylessMultiplyingUpper` on those
targets and in the portable C of WASM, PPC8, Z14 and so on.

Highway's `MaskedMax`, the maximum that zeroes the lanes its mask leaves out, is `svmax_z` on
SVE2_128, so a selected lane is NaN where either operand is NaN, while `Max` and `MaskedMaxOr`
there, like `MaskedMax` on NEON, return the other operand where one is a quiet NaN. So does the
port's `maximum(_:_:where:)` on float lanes.

Highway's `AllBits0` compares `Float` and `Double` lanes with zero, so a vector of `-0.0` counts as
all clear, except on the AVX-512 targets, AVX3, AVX3_DL, AVX3_ZEN4 and AVX3_SPR, where it tests the
bits. So does the port's `allBitsClear`.

Lanes that highway leaves as uninitialized memory, such as the tail of an 8-bit `Compress` on x86,
are not compared.

These differences are deliberate:

- `firstLanes(count:)` on NEON selects every lane for any count of at least `laneCount`, as
  highway's x86 and EMU128 ops do. Highway's NEON op wraps counts above the lane type's signed
  maximum.
- The slide ops' `by:` forms trap on lane amounts outside `0...laneCount`, and the lookup ops'
  `at:` forms on indices outside the range highway defines. The span forms of `lookup8` through
  `lookup64` also trap where `canLookup8` through `canLookup64` is false. The `@unsafe`
  `byUnchecked:`, `atUnchecked:` and `fromUnchecked:` forms, and the lookups' pointer forms, only
  assert it. Above `laneCount`, highway's NEON slides read their index tables out of bounds, and
  its EMU128 `TableLookupLanes` reads outside the vector.
- `reversed4` and `reversed8` trap where `canReverse4` and `canReverse8` are false, on vectors of
  fewer than 4 or 8 lanes. Highway's NEON and x86 ops abort there, its SVE2_128 ops return zeros,
  and its EMU128 ops read and write outside the vector.
- `SIMDFloat16` has arithmetic on every target. Where highway has none for `float16_t` (x86, NEON
  without FP16, and EMU128), the port computes in `Float` and rounds once to `Float16`. Fused ops go
  through `Double`, so every result is correctly rounded.
- `SIMDFloat16` is not available on Intel macOS, where Swift has no `Float16`.

## What is not wrapped

Every op in highway's quick reference is wrapped except `Print` and `MaskFalse`, which is
`repeatingMask(false)`.

swift-vectorization wraps Highway's SIMD ops only. The libraries Highway builds on top of them, such as
`vqsort`, `thread_pool`, `image`, `matvec`, `bit_pack`, `btree`, `unroller`, the `iguana` and
`range_coder` codecs, `profiler` and `nanobenchmark`, are out of scope.
