import Testing
import Vectorization

@Suite("Carry-less multiply")
struct CarrylessMultiplyTests {
    typealias H = SIMDUInt64
    typealias Operands = (a: UInt64, b: UInt64)

    struct Operation {
        let name: String
        let port: (H.Vector, H.Vector) -> H.Vector
        let operandLane: Int
    }

    static func operations() -> [Operation] {
        [
            Operation(
                name: "carrylessMultiplyingLower",
                port: H.carrylessMultiplyingLower,
                operandLane: 0
            ),
            Operation(
                name: "carrylessMultiplyingUpper",
                port: H.carrylessMultiplyingUpper,
                operandLane: 1
            ),
        ]
    }

    static let targetsWithEmulatedCarrylessMultiply = [
        "SSE2", "SSSE3", "NEON_WITHOUT_AES", "SVE2_128", "SVE_256", "SVE", "SVE2", "EMU128",
        "WASM", "PPC8", "PPC9", "PPC10", "Z14", "Z15", "LSX",
    ]

    static let ordinary: [Operands] = [
        (0x1111_1111_1111_1111, 0x1111_1111_1111_1110),
        (.max, 0x0FFF_FFFF_FFFF_FFFF),
        (.max, 1),
        (0, .max),
        (0x8000_0000_0000_0000, 0x8000_0000_0000_0000),
        (0xDEAD_BEEF_CAFE_BABE, 0x0123_4567_89AB_CDEF),
        (0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210),
    ]

    static let bothHaveAFullBitGroup: [Operands] = [
        (0x1111_1111_1111_1111, .max),
        (.max, .max),
        (0x2222_2222_2222_2222, 0x4444_4444_4444_4444),
    ]

    static func product(of a: UInt64, _ b: UInt64) -> (low: UInt64, high: UInt64) {
        var low: UInt64 = 0
        var high: UInt64 = 0
        for shift in 0..<64 where (b >> shift) & 1 != 0 {
            low ^= a << shift
            high ^= a >> (64 - shift)
        }
        return (low, high)
    }

    func verify(
        _ operation: Operation,
        _ cases: [Operands],
        checking lanes: (Int) -> Bool = { _ in true }
    ) {
        let laneCount = H.laneCount
        var mismatches: [String] = []
        for offset in cases.indices {
            let chosen = (0..<laneCount).map { cases[($0 + offset) % cases.count] }
            let a = ContiguousArray(chosen.map(\.a))
            let b = ContiguousArray(chosen.map(\.b))
            var output = ContiguousArray<UInt64>(repeating: 0, count: laneCount)

            var destination = output.mutableSpan
            H.store(operation.port(H.load(from: a.span), H.load(from: b.span)), to: &destination)

            for lane in 0..<laneCount where lanes(lane) {
                let operands = chosen[lane - lane % 2 + operation.operandLane]
                let product = Self.product(of: operands.a, operands.b)
                let expected = lane.isMultiple(of: 2) ? product.low : product.high
                if output[lane] != expected {
                    mismatches.append(
                        "\(String(operands.a, radix: 16)) \(String(operands.b, radix: 16)): lane \(lane) is \(String(output[lane], radix: 16)) instead of \(String(expected, radix: 16))"
                    )
                }
            }
        }
        #expect(mismatches.isEmpty, "\(operation.name): \(mismatches.prefix(4))")
    }

    @Test("Ordinary operands multiply exactly")
    func ordinaryOperands() {
        for operation in Self.operations() {
            verify(operation, Self.ordinary)
        }
    }

    @Test("The lower 64 bits are exact when both operands have a fully set bit group")
    func lowerHalfOfFullBitGroups() {
        for operation in Self.operations() {
            verify(operation, Self.bothHaveAFullBitGroup) { $0.isMultiple(of: 2) }
        }
    }

    @Test("The upper 64 bits are exact when both operands have a fully set bit group")
    func upperHalfOfFullBitGroups() {
        for operation in Self.operations() {
            for operands in Self.bothHaveAFullBitGroup {
                withKnownIssue(
                    "Highway emulates the carry-less multiply on targets without an instruction for it, and the port does the same there and in its portable C, which gets the upper 64 bits of the product wrong when both operands have all 16 bits of a group of every fourth bit set"
                ) {
                    verify(operation, [operands]) { !$0.isMultiple(of: 2) }
                } when: {
                    Self.targetsWithEmulatedCarrylessMultiply.contains(SIMDTarget.targetName)
                }
            }
        }
    }
}
