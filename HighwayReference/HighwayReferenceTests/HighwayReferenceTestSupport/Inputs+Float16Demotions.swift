package protocol Float16DemotionLane: ReferenceLane, BinaryFloatingPoint {
    static var nanPatterns: [Self] { get }
}

extension Float: Float16DemotionLane {
    package static var nanPatterns: [Float] {
        let patterns: [UInt32] = [
            0x7F80_0001, 0x7F80_1FFF, 0x7F80_2000, 0x7FBF_E000, 0x7FC0_0000, 0x7FC0_1FFF,
            0x7FFF_FFFF, 0xFF80_0001, 0xFFBF_E000, 0xFFC0_0000, 0xFFFF_E000,
        ]
        return patterns.map { Float(bitPattern: $0) }
    }
}

extension Double: Float16DemotionLane {
    package static var nanPatterns: [Double] {
        let patterns: [UInt64] = [
            0x7FF0_0000_0000_0001, 0x7FF0_0000_1FFF_FFFF, 0x7FF0_0000_2000_0000,
            0x7FF7_FFFF_E000_0000, 0x7FF8_0000_0000_0000, 0x7FF8_0000_1FFF_FFFF,
            0x7FFF_FFFF_FFFF_FFFF, 0xFFF0_0000_0000_0001, 0xFFF7_FFFF_E000_0000,
            0xFFF8_0000_0000_0000, 0xFFFF_FFFF_E000_0000,
        ]
        return patterns.map { Double(bitPattern: $0) }
    }
}

private enum Float16Boundaries {
    static let patterns: [UInt16] = [
        0x0001, 0x0002, 0x0003, 0x01FF, 0x0200, 0x03FE, 0x03FF, 0x0400, 0x0401, 0x0402, 0x1000,
        0x3555, 0x3BFF, 0x3C00, 0x3C01, 0x3C02, 0x4000, 0x4001, 0x5BFF, 0x7800, 0x7801, 0x7BFD,
        0x7BFE, 0x7BFF,
    ]

    static func value(of pattern: UInt16) -> Double {
        let exponent = Int(pattern >> 10)
        let fraction = Double(pattern & 0x3FF)
        guard exponent > 0 else { return fraction * 0x1p-24 }
        return (1 + fraction / 1024) * Double(sign: .plus, exponent: exponent - 15, significand: 1)
    }

    static var magnitudes: [Double] {
        var values: [Double] = [0, 0x1p-26, 0x1p-25]
        for pattern in patterns {
            let low = value(of: pattern)
            let high = value(of: pattern + 1)
            values += [low, (low + high) / 2, high]
        }
        return values
    }
}

extension Float16DemotionLane {
    package static var float16DemotionEdges: [Self] {
        var positive: [Self] = [.greatestFiniteMagnitude, .leastNormalMagnitude]
        positive += [.leastNonzeroMagnitude, .infinity]
        for magnitude in Float16Boundaries.magnitudes {
            let value = Self(magnitude)
            positive += [value, value.nextDown, value.nextUp]
        }
        return positive + positive.map { -$0 } + nanPatterns
    }
}

extension Inputs {
    package static func float16Demotions<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: Float16DemotionLane {
        let edges = V.Scalar.float16DemotionEdges
        let splats = edges.map { V(repeating: $0) }
        let windows = edges.indices.map { offset in
            V((0..<V.scalarCount).map { edges[($0 + offset) % edges.count] })
        }
        return conversions(type, seed: seed) + splats + windows
    }
}
