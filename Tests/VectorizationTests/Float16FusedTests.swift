#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
import Testing
import Vectorization

@Suite("Float16 fused multiply-add")
struct Float16FusedTests {
    typealias Vector = SIMDFloat16.Vector

    struct Fused {
        let name: String
        let port: (Vector, Vector, Vector) -> Vector
        let expected: (Double, Double, Double, Int) -> Double
    }

    static func operations() -> [Fused] {
        [
            Fused(name: "multiplyAdding", port: SIMDFloat16.multiplyAdding) { a, b, c, _ in
                c + a * b
            },
            Fused(name: "negatedMultiplyAdding", port: SIMDFloat16.negatedMultiplyAdding) {
                a,
                b,
                c,
                _ in c - a * b
            },
            Fused(name: "multiplySubtracting", port: SIMDFloat16.multiplySubtracting) {
                a,
                b,
                c,
                _ in a * b - c
            },
            Fused(
                name: "negatedMultiplySubtracting",
                port: SIMDFloat16.negatedMultiplySubtracting
            ) { a, b, c, _ in -(a * b) - c },
            Fused(
                name: "multiplyAddingSubtracting",
                port: SIMDFloat16.multiplyAddingSubtracting
            ) { a, b, c, lane in lane.isMultiple(of: 2) ? a * b - c : a * b + c },
            Fused(
                name: "multiplySubtractingAdding",
                port: SIMDFloat16.multiplySubtractingAdding
            ) { a, b, c, lane in lane.isMultiple(of: 2) ? a * b + c : a * b - c },
        ]
    }

    static let hardTriples: [(UInt16, UInt16, UInt16)] = [
        (0x9AD8, 0x6180, 0x8002), (0x4D20, 0x5430, 0x8400), (0x590E, 0xAD00, 0x0008),
        (0xDC2C, 0x4580, 0x8200), (0x6500, 0x31FA, 0x0080), (0x6F00, 0xB4EC, 0x8800),
        (0x3C01, 0x3C01, 0x0001), (0x3BFF, 0x3C01, 0x8001), (0x0001, 0x3800, 0x0001),
    ]

    static func halfUnitAddends(of a: Float16, _ b: Float16) -> [Float16] {
        let product = Double(a) * Double(b)
        guard product != 0, product.isFinite else { return [] }
        return (-1...1).flatMap { offset -> [Float16] in
            let exponent = min(15, max(-24, Int(product.exponent) - 24 + offset))
            let addend = Float16(sign: .plus, exponent: exponent, significand: 1)
            return [addend, -addend]
        }
    }

    func verify(_ triples: [(Float16, Float16, Float16)]) {
        for operation in Self.operations() {
            var mismatches: [String] = []
            let laneCount = SIMDFloat16.laneCount
            for start in stride(from: 0, to: triples.count, by: laneCount) {
                let chunk = (0..<laneCount).map { triples[min(start + $0, triples.count - 1)] }
                let result = operation.port(
                    Vector(chunk.map(\.0)),
                    Vector(chunk.map(\.1)),
                    Vector(chunk.map(\.2))
                )
                for lane in 0..<laneCount {
                    let (a, b, c) = chunk[lane]
                    let expected = Float16(
                        operation.expected(Double(a), Double(b), Double(c), lane)
                    )
                    let same =
                        expected.isNaN
                        ? result[lane].isNaN : expected.bitPattern == result[lane].bitPattern
                    if !same {
                        mismatches.append(
                            "\(a.bitPattern) \(b.bitPattern) \(c.bitPattern): \(result[lane].bitPattern) instead of \(expected.bitPattern)"
                        )
                    }
                }
            }
            #expect(mismatches.isEmpty, "\(operation.name): \(mismatches.prefix(4))")
        }
    }

    @Test func roundsOnce() {
        verify(
            Self.hardTriples.map {
                (Float16(bitPattern: $0), Float16(bitPattern: $1), Float16(bitPattern: $2))
            }
        )
    }

    @Test func roundsOnceAtHalfAUnitOfSinglePrecision() {
        var triples: [(Float16, Float16, Float16)] = []
        for pattern in stride(from: 0, to: 0x10000, by: 7) {
            let a = Float16(bitPattern: UInt16(pattern))
            guard a.isFinite else { continue }
            for round in 1...3 {
                let other = pattern &* 40503 &* round &+ 977 &* round
                let b = Float16(bitPattern: UInt16(truncatingIfNeeded: other))
                guard b.isFinite else { continue }
                triples += Self.halfUnitAddends(of: a, b).map { (a, b, $0) }
            }
        }
        verify(triples)
    }
}
#endif
