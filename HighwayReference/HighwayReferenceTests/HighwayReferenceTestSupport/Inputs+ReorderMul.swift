extension Inputs {
    package static func accumulators<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane & FixedWidthInteger {
        let edges = accumulatorEdges(V.Scalar.self)
        let splats = edges.map { V(repeating: $0) }
        let rotations = edges.indices.map { offset in
            V((0..<V.scalarCount).map { edges[($0 + offset) % edges.count] })
        }
        return vectors(type, seed: seed) + splats + rotations
    }

    package static func accumulators<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Simd.Scalar: FixedWidthInteger {
        accumulators(V.Simd.self, seed: seed).map(V.init)
    }

    private static func accumulatorEdges<Lane: FixedWidthInteger>(_ type: Lane.Type) -> [Lane] {
        let halfBits = Lane.bitWidth / 2
        let unsignedLimit = (UInt64(1) << halfBits) - 1
        let signedLimit = Int64(1) << (halfBits - 1)
        let products: [Lane] = [
            Lane(truncatingIfNeeded: unsignedLimit * unsignedLimit),
            Lane(truncatingIfNeeded: UInt64(1) << (Lane.bitWidth - 2)),
            Lane(truncatingIfNeeded: (signedLimit - 1) * (signedLimit - 1)),
            Lane(truncatingIfNeeded: -signedLimit * (signedLimit - 1)),
        ]
        let sums = products.map { $0 &+ $0 }
        let nearProducts = (products + sums).flatMap { product -> [Lane] in
            [
                product, 0 &- product, .max &- product, .max &- product &+ 1, .min &+ product,
                .min &+ product &- 1,
            ]
        }
        let bounds: [Lane] = [0, 1, .max, .min, .max - 1, .min + 1]
        return (bounds + nearProducts).reduce(into: []) { unique, value in
            if !unique.contains(value) {
                unique.append(value)
            }
        }
    }
}
