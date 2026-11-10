extension Inputs {
    package static func widenMulOperands<V: ReferenceVector>(_ type: V.Type) -> [V]
    where V.Simd.Scalar: FixedWidthInteger {
        typealias Lane = V.Simd.Scalar
        var lanes = Lane.edges
        if !lanes.contains(~0) {
            lanes.append(~0)
        }
        let splats = lanes.map { V(V.Simd(repeating: $0)) }
        let extremes: [(Lane, Lane)] = [
            (Lane.min, Lane.max), (Lane.max, Lane.min), (Lane.min, Lane.min + 1),
            (Lane.max, Lane.max - 1),
        ]
        let alternating = extremes.map { first, second in
            V(V.Simd((0..<V.Simd.scalarCount).map { $0 % 2 == 0 ? first : second }))
        }
        return splats + alternating
    }

    package static func widenMulAccumulators<V: ReferenceVector>(_ type: V.Type) -> [V]
    where V.Simd.Scalar: FixedWidthInteger {
        typealias Lane = V.Simd.Scalar
        var lanes: [Lane] = [0, 1, ~0, Lane.min, Lane.min + 1, Lane.max, Lane.max - 1]
        for exponent in [8, 15, 16, 17, 31, 32, 33] where exponent < Lane.bitWidth {
            let step = Lane(truncatingIfNeeded: 1) << exponent
            for offset in -1...1 {
                let shift = Lane(truncatingIfNeeded: offset)
                lanes.append(Lane.max &- step &+ shift)
                lanes.append(Lane.min &+ step &+ shift)
            }
        }
        let unique = lanes.reduce(into: [Lane]()) { unique, lane in
            if !unique.contains(lane) {
                unique.append(lane)
            }
        }
        let splats = unique.map { V(V.Simd(repeating: $0)) }
        let rotations = unique.indices.map { offset in
            V(V.Simd((0..<V.Simd.scalarCount).map { unique[($0 + offset) % unique.count] }))
        }
        return splats + rotations
    }
}
