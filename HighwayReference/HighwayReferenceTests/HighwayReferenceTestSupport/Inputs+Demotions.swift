package protocol DemotionLane: ReferenceLane {
    static var demotionEdges: [Self] { get }
}

extension Double: DemotionLane {
    package static var demotionEdges: [Double] {
        var positive: [Double] = []
        for limit: Double in [2_147_483_647, 2_147_483_648, 4_294_967_295, 4_294_967_296] {
            positive += [limit - 1, limit - 0.5, limit, limit + 0.5, limit + 1]
        }
        let greatest = Double(Float.greatestFiniteMagnitude)
        let overflow = 0x1p128 - 0x1p103
        let smallest = Double(Float.leastNonzeroMagnitude)
        let normal = Double(Float.leastNormalMagnitude)
        var singles: [Double] = [greatest, overflow, 0x1p128, smallest, normal]
        singles += [1 + 0x1p-24, 0x1p24 + 1, 0x1p24 + 3, smallest / 2, normal - smallest / 2]
        positive += singles
        for single in singles {
            positive += [single.nextDown, single.nextUp]
        }
        return positive + positive.map { -$0 }
    }
}

extension FixedWidthInteger where Self: DemotionLane {
    fileprivate static var floatRoundingEdges: [Self] {
        let one: Self = 1
        let widest = bitWidth - (isSigned ? 1 : 0)
        var positive: [Self] = []
        for exponent in 24..<widest {
            let tie = (one << exponent) + (one << (exponent - 24))
            let next = tie + (one << (exponent - 23))
            for edge in [tie, next] {
                positive += [edge - 1, edge, edge + 1]
            }
        }
        guard isSigned else { return positive }
        return positive + positive.map { 0 &- $0 }
    }
}

extension Int64: DemotionLane {
    package static var demotionEdges: [Int64] { floatRoundingEdges }
}

extension UInt64: DemotionLane {
    package static var demotionEdges: [UInt64] { floatRoundingEdges }
}

extension Inputs {
    package static func floatDemotions<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: DemotionLane {
        let edges = V.Scalar.demotionEdges
        let splats = edges.map { V(repeating: $0) }
        let windows = edges.indices.map { offset in
            V((0..<V.scalarCount).map { edges[($0 + offset) % edges.count] })
        }
        return conversions(type, seed: seed) + splats + windows
    }

    package static func floatDemotions<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Simd.Scalar: DemotionLane {
        floatDemotions(V.Simd.self, seed: seed).map(V.init)
    }
}
