extension Inputs {
    package static func exponents<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane & FixedWidthInteger & SignedInteger {
        var generator = SplitMix64(seed: seed)
        let bias = V.Scalar.bitWidth == 32 ? 127 : 1023
        let mantissaBits = V.Scalar.bitWidth == 32 ? 23 : 52
        var critical: [Int] = [Int(V.Scalar.min), Int(V.Scalar.min) + 1]
        critical += [Int(V.Scalar.max) - 1, Int(V.Scalar.max)]
        for multiple in -3...3 {
            critical += (-2...2).map { multiple * bias + $0 }
        }
        for offset in -2...2 {
            critical += [bias + mantissaBits + 1 + offset, -(bias + mantissaBits + 1 + offset)]
        }
        for offset in -3...3 {
            critical += [offset, 1100 + offset, -1100 + offset]
        }
        for power in 4..<(V.Scalar.bitWidth - 1) {
            critical += [1 << power, (1 << power) - 1, -(1 << power)]
        }
        let sorted = Set(critical).sorted()
        func lane(_ value: Int) -> V.Scalar { V.Scalar(truncatingIfNeeded: value) }
        let splats = sorted.map { V(repeating: lane($0)) }
        let windows = sorted.indices.map { offset in
            V((0..<V.scalarCount).map { lane(sorted[(offset + $0) % sorted.count]) })
        }
        let reach = UInt64(6 * bias + 101)
        let random = (0..<randomCount).map { _ in
            V(
                (0..<V.scalarCount).map { _ in
                    switch generator.next() % 3 {
                    case 0: return lane(sorted[Int(generator.next() % UInt64(sorted.count))])
                    case 1: return lane(Int(generator.next() % reach) - 3 * bias - 50)
                    default: return V.Scalar.random(using: &generator)
                    }
                }
            )
        }
        return conversions(type, seed: seed) + splats + windows + random
    }

    package static func exponents<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Simd.Scalar: FixedWidthInteger & SignedInteger {
        exponents(V.Simd.self, seed: seed).map(V.init)
    }

    package static func byteIndices<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane & FixedWidthInteger {
        let sweeps = (0..<256).map { start in
            V((0..<V.scalarCount).map { V.Scalar(truncatingIfNeeded: start + $0) })
        }
        let splats = (0..<256).map { V(repeating: V.Scalar(truncatingIfNeeded: $0)) }
        return conversions(type, seed: seed) + sweeps + splats
    }

    package static func byteIndices<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Simd.Scalar: FixedWidthInteger {
        byteIndices(V.Simd.self, seed: seed).map(V.init)
    }
}
