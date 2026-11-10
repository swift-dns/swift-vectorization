package import Vectorization

extension Float {
    fileprivate static var bfloat16DemotionEdges: [Float] {
        let upperBits = BFloat16.edges.map(\.bitPattern) + [0x3F81, 0xBF81, 0x4021, 0x0002, 0x007E]
        let lowerBits: [UInt32] = [0, 1, 0x4000, 0x7FFF, 0x8000, 0x8001, 0xC000, 0xFFFF]
        return upperBits.flatMap { upper in
            lowerBits.map { Float(bitPattern: UInt32(upper) << 16 | $0) }
        }
    }
}

extension Inputs {
    package static func bfloat16Demotions<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar == Float {
        let edges = Float.bfloat16DemotionEdges
        let splats = edges.map { V(repeating: $0) }
        let windows = edges.indices.map { offset in
            V((0..<V.scalarCount).map { edges[($0 + offset) % edges.count] })
        }
        return conversions(type, seed: seed) + splats + windows
    }

    package static func accumulators<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane & BinaryFloatingPoint {
        vectors(type, seed: seed)
    }
}

private enum NaNTerm: Hashable {
    case ordinary
    case invalid
    case payload(UInt32)

    init(_ value: Float) {
        self = value.isNaN ? .payload(value.bitPattern | 0x0040_0000) : .ordinary
    }
}

private func product(of first: Float, _ second: Float) -> NaNTerm? {
    switch (NaNTerm(first), NaNTerm(second)) {
    case (.ordinary, .ordinary):
        let isInvalid = (first.isInfinite && second == 0) || (second.isInfinite && first == 0)
        return isInvalid ? .invalid : .ordinary
    case (.ordinary, let term), (let term, .ordinary):
        return term
    case (let firstTerm, let secondTerm):
        return firstTerm == secondTerm ? firstTerm : nil
    }
}

private func isUnordered(_ terms: NaNTerm?...) -> Bool {
    guard !terms.contains(nil) else { return true }
    return Set(terms.compactMap { $0 }.filter { $0 != .ordinary }).count > 1
}

private func widenedProduct<A: ReferenceVector>(_ a: A, _ b: A, _ lane: Int) -> NaNTerm?
where A.InputLane == BFloat16, A.Simd.Scalar == UInt16 {
    func value(_ vector: A) -> Float {
        Float(BFloat16(bitPattern: vector.simd[lane]))
    }
    return product(of: value(a), value(b))
}

package func hasUnorderedNaNs<A: ReferenceVector>(widening a: A, _ b: A) -> Bool
where A.InputLane == BFloat16, A.Simd.Scalar == UInt16 {
    (0..<A.Simd.scalarCount / 2).contains { lane in
        isUnordered(widenedProduct(a, b, 2 * lane), widenedProduct(a, b, 2 * lane + 1))
    }
}

package func hasUnorderedNaNs<A: ReferenceVector, V: SIMD>(
    widening a: A,
    _ b: A,
    parity: Int,
    adding c: V
) -> Bool where A.InputLane == BFloat16, A.Simd.Scalar == UInt16, V.Scalar == Float {
    (0..<V.scalarCount).contains { lane in
        isUnordered(widenedProduct(a, b, 2 * lane + parity), NaNTerm(c[lane]))
    }
}

package func hasUnorderedNaNs<A: ReferenceVector, V: SIMD>(
    widening a: A,
    _ b: A,
    accumulating c: V,
    _ v0: V
) -> Bool where A.InputLane == BFloat16, A.Simd.Scalar == UInt16, V.Scalar == Float {
    (0..<V.scalarCount).contains { lane in
        isUnordered(widenedProduct(a, b, 2 * lane), NaNTerm(c[lane]))
            || isUnordered(widenedProduct(a, b, 2 * lane + 1), NaNTerm(v0[lane]))
    }
}

package func hasFoldedNaNs<A: ReferenceVector>(multiplier: BFloat16, _ other: A) -> Bool
where A.InputLane == BFloat16, A.Simd.Scalar == UInt16 {
    Float(multiplier) == -1
        && (0..<A.Simd.scalarCount).contains { Float(BFloat16(bitPattern: other.simd[$0])).isNaN }
}
