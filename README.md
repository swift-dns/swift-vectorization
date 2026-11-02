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

Each element type has its own namespace of ops, such as `SIMDUInt8`, and `SIMDElement` lets a kernel be written once for all of them:

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
| arm64    | SVE2_128                             | 16    | With `-Xcc -march=armv9-a -Xcc -msve-vector-bits=128`.                                                                      |
| x86_64   | SSE2, SSSE3, SSE4                    | 16    | SSE2 is the baseline, SSSE3 on Apple platforms and Android. SSE4 needs `-Xcc -march=x86-64-v2 -Xcc -maes -Xcc -mpclmul`.    |
| x86_64   | AVX2                                 | 32    | With `-Xcc -march=x86-64-v3 -Xcc -maes -Xcc -mpclmul`, or a CPU such as `-Xcc -march=skylake`.                              |
| x86_64   | AVX3, AVX3_DL, AVX3_ZEN4, AVX3_SPR   | 64    | With AVX-512 flags, such as `-Xcc -march=skylake-avx512` or `-Xcc -march=icelake-server`.                                   |
| Others   | EMU128, or WASM, PPC8, Z14 and so on | 16    | Portable C, which the compiler lowers to the SIMD the platform has, or to scalar code. `targetName` names highway's target. |

Like highway, SSE4 and AVX2 also need AES and PCLMUL, so `-Xcc -march=x86-64-v3` alone gives SSSE3.
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

## How it relates to highway

Every op reproduces what highway does on the same target, down to NaN payloads and the results of
out-of-range inputs, so the ops behave like highway's. `HighwayReference/` holds a copy of highway
and generated tests that compare every op with highway's, lane for lane, on NEON, NEON_WITHOUT_AES,
SVE2_128, SSE2, SSSE3, SSE4, AVX2, the AVX-512 targets under Intel's SDE, and highway's EMU128.

When an op meets two NaNs with different payloads, as in an addition, a multiplication, a sum, or a
minimum or maximum on SVE, which payload comes out is up to the compiler, in highway as in the port.

Two differences are deliberate:

- `firstLanes(count:)` on NEON selects every lane for any count of at least `laneCount`, as
  highway's x86 and EMU128 ops do. Highway's NEON op wraps counts above the lane type's signed
  maximum.
- The slide ops' `by:` forms trap on lane amounts outside `0...laneCount`, and the lookup ops'
  `at:` forms on indices outside the range highway defines. Their `@unsafe` `byUnchecked:` and
  `atUnchecked:` forms only assert it. Above `laneCount`, highway's NEON slides read their index
  tables out of bounds, and its EMU128 `TableLookupLanes` reads outside the vector.

## What is not wrapped

swift-vectorization wraps Highway's SIMD ops only. The libraries Highway builds on top of them, such as
`vqsort`, `thread_pool`, `image`, `matvec`, `bit_pack`, `btree`, `unroller`, the `iguana` and
`range_coder` codecs, `profiler` and `nanobenchmark`, are out of scope.
