public import Vectorization

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@available(SwiftStdlib 5.3, *)
extension Float16: ReferenceLane {
    @usableFromInline
    package var bits: UInt16 { bitPattern }

    @usableFromInline
    package static var edges: [Float16] {
        let limits: [Float16] = [0x1p14, 0x1p15, 65504]
        let patterns: [UInt16] = [0x7C01, 0x7E01, 0x7FFF, 0xFC01, 0xFE01, 0xFFFF, 0x0001, 0x03FF]
        return [
            0, -0.0, 1, -1, 0.5, -0.5, 1.5, 2.5, -2.5, .ulpOfOne, .infinity, -.infinity,
            .nan, -.nan, .signalingNaN, Float16(nan: 1, signaling: false), .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude,
        ]
            + limits.flatMap { limit in
                [limit, limit.nextDown, limit.nextUp, -limit, (-limit).nextDown, (-limit).nextUp]
            }
            + patterns.map { Float16(bitPattern: $0) }
    }

    @usableFromInline
    package static var conversionEdges: [Float16] {
        var positive: [Float16] = [1024.5, 2047.5, 2048, 4096, 16384, 32752, 32768, 65504]
        for tie: Float16 in [0.5, 1, 1.5, 2.5, 3.5] {
            positive += [tie, tie.nextDown, tie.nextUp]
        }
        return positive + positive.map { -$0 }
    }

    @usableFromInline
    package static func random(using generator: inout SplitMix64) -> Float16 {
        let raw = generator.next()
        guard raw & 3 != 0 else {
            return Float16(bitPattern: UInt16(truncatingIfNeeded: raw >> 32))
        }
        return Float16(Float(Int32(truncatingIfNeeded: raw >> 32) % 60_000) / 16)
    }
}
#endif

extension BFloat16: Codable, ReferenceLane {
    @usableFromInline
    package var bits: UInt16 { bitPattern }

    @usableFromInline
    package static var edges: [BFloat16] {
        let patterns: [UInt16] = [
            0x0000, 0x8000, 0x3F80, 0xBF80, 0x3F00, 0xBF00, 0x3FC0, 0x4020, 0xC020, 0x7F80, 0xFF80,
            0x7FC0, 0xFFC0, 0x7F81, 0x7FBF, 0xFF81, 0x7FFF, 0xFFFF, 0x0001, 0x8001, 0x007F, 0x0080,
            0x7F7F, 0xFF7F, 0x7F7E, 0x4780, 0x477F, 0x4781,
        ]
        return patterns.map { BFloat16(bitPattern: $0) }
    }

    @usableFromInline
    package static var conversionEdges: [BFloat16] {
        edges.filter { Float($0).isFinite }
    }

    @usableFromInline
    package static func random(using generator: inout SplitMix64) -> BFloat16 {
        let raw = generator.next()
        guard raw & 3 != 0 else {
            return BFloat16(bitPattern: UInt16(truncatingIfNeeded: raw >> 32))
        }
        return BFloat16(Float(Int32(truncatingIfNeeded: raw >> 32) % 1_000_000) / 1000)
    }

    public init(from decoder: any Decoder) throws {
        self.init(bitPattern: try decoder.singleValueContainer().decode(UInt16.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bitPattern)
    }
}
