# Notice

## swift-vectorization

This product implements the SIMD ops of [highway](https://github.com/google/highway), Google's
portable SIMD library, for Swift. Its C code follows highway's implementation of each op on each
target.

## Vendored code

`HighwayReference/CHighway/include/hwy` is a verbatim copy of highway, taken at the commit recorded
in [highway-version.json](highway-version.json), and `HighwayReference/CHighway/quick_reference.md`
is highway's op reference from the same commit. They are used by the `HighwayReference` test
package only, not by the product. They are not edited by hand: `scripts/vendor-highway.sh` replaces them from upstream,
and CI fails if the committed copy differs from what that script produces.

highway is dual-licensed under your choice of the Apache License 2.0 or the BSD 3-Clause
License. Its license text is kept alongside the copy, at
[HighwayReference/CHighway/LICENSE](HighwayReference/CHighway/LICENSE), and is also this
package's [LICENSE](LICENSE).

    Copyright 2019 Google LLC
    SPDX-License-Identifier: Apache-2.0
    SPDX-License-Identifier: BSD-3-Clause
