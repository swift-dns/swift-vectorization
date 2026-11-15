#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
import Testing
import Vectorization

private struct ComplexProducts<Lane> {
    let merged: [Lane]
    let conjugated: [Lane]
    let accumulated: [Lane]
}

private func lanes<E: SIMDElement>(_ type: E.Type, _ vector: E.Vector) -> [E.Lane] {
    let output = ContiguousArray<E.Lane>(capacity: E.laneCount) { output in
        E.append(vector, to: &output)
    }
    return Array(output)
}

private func maskedComplexProducts<E: SIMDElement>(
    _ type: E.Type,
    _ a: ContiguousArray<E.Lane>,
    _ b: ContiguousArray<E.Lane>,
    _ c: ContiguousArray<E.Lane>,
    selectedBy selector: ContiguousArray<E.Lane>
) -> ComplexProducts<E.Lane> {
    let mask = E.notEqualTo(E.load(from: selector.span), E.zero())
    let (a, b, c) = (E.load(from: a.span), E.load(from: b.span), E.load(from: c.span))
    return ComplexProducts(
        merged: lanes(E.self, E.multiplyingComplex(a, b, where: mask, otherwise: c)),
        conjugated: lanes(E.self, E.multiplyingComplexConjugate(a, b, where: mask)),
        accumulated: lanes(E.self, E.multiplyAddingComplexConjugate(a, b, c, where: mask))
    )
}

private func composedComplexProducts<E: SIMDElement>(
    _ type: E.Type,
    _ a: ContiguousArray<E.Lane>,
    _ b: ContiguousArray<E.Lane>,
    _ c: ContiguousArray<E.Lane>,
    selectedBy selector: ContiguousArray<E.Lane>
) -> ComplexProducts<E.Lane> {
    let mask = E.notEqualTo(E.load(from: selector.span), E.zero())
    let (a, b, c) = (E.load(from: a.span), E.load(from: b.span), E.load(from: c.span))
    return ComplexProducts(
        merged: lanes(E.self, E.selecting(mask, E.multiplyingComplex(a, b), c)),
        conjugated: lanes(E.self, E.selectingOrZero(mask, E.multiplyingComplexConjugate(a, b))),
        accumulated: lanes(
            E.self,
            E.selectingOrZero(mask, E.multiplyAddingComplexConjugate(a, b, c))
        )
    )
}

private struct FloatLanes<Lane> {
    let roots: [Lane]
    let negated: [Lane]
    let floors: [Lane]
}

private func floatLanes<E: SIMDFloatElement>(
    _ type: E.Type,
    _ input: ContiguousArray<E.Lane>
) -> FloatLanes<E.Lane> {
    let vector = E.load(from: input.span)
    return FloatLanes(
        roots: lanes(E.self, E.squareRoot(E.magnitude(vector))),
        negated: lanes(E.self, E.negated(vector)),
        floors: lanes(E.self, E.roundedDown(vector))
    )
}

@Suite("Float16 as a SIMDElement")
struct Float16ElementTests {
    typealias Complex = (real: Float16, imaginary: Float16)

    struct Window {
        let a: ContiguousArray<Float16>
        let b: ContiguousArray<Float16>
        let c: ContiguousArray<Float16>
        let selector: ContiguousArray<Float16>
    }

    static let exactParts: [Float16] = [-4, -2, -1, -0.5, 0, 0.5, 1, 2, 3, 4]

    static let hardParts: [Float16] = [
        0x0000, 0x8000, 0x3C00, 0xBC00, 0x3C01, 0x3BFF, 0x0001, 0x03FF, 0x7BFF, 0xFBFF, 0x7C00,
        0xFC00, 0x7E00, 0x5640, 0x2E66,
    ].map { Float16(bitPattern: $0) }

    static func windows(of parts: [Float16]) -> [Window] {
        let numbers: [Complex] = parts.flatMap { real in parts.map { (real, $0) } }
        let triples = numbers.indices.flatMap { first in
            numbers.indices.map { second in
                (
                    numbers[first], numbers[second],
                    numbers[(first &* 7 &+ second &* 3) % numbers.count]
                )
            }
        }
        let complexLanes = SIMDFloat16.laneCount / 2
        return stride(from: 0, to: triples.count, by: complexLanes).map { start in
            let chunk = (0..<complexLanes).map { triples[(start + $0) % triples.count] }
            return Window(
                a: ContiguousArray(chunk.flatMap { [$0.0.real, $0.0.imaginary] }),
                b: ContiguousArray(chunk.flatMap { [$0.1.real, $0.1.imaginary] }),
                c: ContiguousArray(chunk.flatMap { [$0.2.real, $0.2.imaginary] }),
                selector: ContiguousArray(
                    (0..<SIMDFloat16.laneCount).map { (start + $0) % 3 == 0 ? 0 : 1 }
                )
            )
        }
    }

    private static func product(
        _ window: Window,
        lane: Int,
        conjugating: Bool,
        adding: Bool
    ) -> Float16 {
        let pair = lane & ~1
        let (ar, ai) = (Double(window.a[pair]), Double(window.a[pair + 1]))
        let (br, bi) = (Double(window.b[pair]), Double(window.b[pair + 1]))
        let value =
            switch (conjugating, lane.isMultiple(of: 2)) {
            case (false, true): ar * br - ai * bi
            case (false, false): ar * bi + ai * br
            case (true, true): ar * br + ai * bi
            case (true, false): ai * br - ar * bi
            }
        return Float16(adding ? value + Double(window.c[lane]) : value)
    }

    private static func expected(_ window: Window) -> ComplexProducts<Float16> {
        func products(
            conjugating: Bool,
            adding: Bool,
            unselected: (Int) -> Float16
        ) -> [Float16] {
            (0..<SIMDFloat16.laneCount).map { lane in
                window.selector[lane] != 0
                    ? product(window, lane: lane, conjugating: conjugating, adding: adding)
                    : unselected(lane)
            }
        }
        return ComplexProducts(
            merged: products(conjugating: false, adding: false) { window.c[$0] },
            conjugated: products(conjugating: true, adding: false) { _ in 0 },
            accumulated: products(conjugating: true, adding: true) { _ in 0 }
        )
    }

    private func verify(
        _ windows: [Window],
        against expected: (Window) -> ComplexProducts<Float16>,
        compares: (Float16, Float16) -> Bool
    ) {
        var mismatches: [String] = []
        for window in windows {
            let got = maskedComplexProducts(
                SIMDFloat16.self,
                window.a,
                window.b,
                window.c,
                selectedBy: window.selector
            )
            let want = expected(window)
            for (name, got, want) in [
                ("merged", got.merged, want.merged),
                ("conjugated", got.conjugated, want.conjugated),
                ("accumulated", got.accumulated, want.accumulated),
            ] {
                for lane in 0..<SIMDFloat16.laneCount where !compares(got[lane], want[lane]) {
                    mismatches.append(
                        "\(name) lane \(lane): \(got[lane].bitPattern) instead of \(want[lane].bitPattern) for \(window.a.map(\.bitPattern)) \(window.b.map(\.bitPattern)) \(window.c.map(\.bitPattern))"
                    )
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(2))")
    }

    private static func composed(_ window: Window) -> ComplexProducts<Float16> {
        composedComplexProducts(
            SIMDFloat16.self,
            window.a,
            window.b,
            window.c,
            selectedBy: window.selector
        )
    }

    @Test("The masked complex products multiply the selected lanes exactly")
    func multipliesSelectedLanes() {
        verify(Self.windows(of: Self.exactParts), against: Self.expected, compares: ==)
    }

    @Test("The masked complex products equal the unmasked ones selected by the mask")
    func equalsTheComposition() {
        verify(
            Self.windows(of: Self.hardParts),
            against: Self.composed,
            compares: { $0.bitPattern == $1.bitPattern }
        )
    }

    @Test("A generic float kernel computes the lanes of Float16")
    func computesFloatLanes() {
        let values = Self.hardParts + Self.exactParts
        var mismatches: [String] = []
        for start in values.indices {
            let input = ContiguousArray(
                (0..<SIMDFloat16.laneCount).map { values[(start + 3 * $0) % values.count] }
            )
            let got = floatLanes(SIMDFloat16.self, input)
            for (lane, value) in input.enumerated() {
                for (name, have, want) in [
                    ("root", got.roots[lane], value.magnitude.squareRoot()),
                    ("negated", got.negated[lane], -value),
                    ("floor", got.floors[lane], value.rounded(.down)),
                ] where want.isNaN ? !have.isNaN : have.bitPattern != want.bitPattern {
                    mismatches.append(
                        "\(name) of \(value.bitPattern): \(have.bitPattern) instead of \(want.bitPattern)"
                    )
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(2))")
    }

    @Test(
        "allBitsClear compares Float16 lanes with zero where highway does, so -0.0 counts as zero"
    )
    func allBitsClearOfNegativeZero() {
        typealias H = SIMDFloat16
        let comparesAsFloat16 =
            SIMDTarget.hasNativeFloat16Arithmetic || SIMDTarget.targetName == "EMU128"
        let negativeZeros = ContiguousArray<Float16>(repeating: -0.0, count: H.laneCount)
        let oneNegativeZero = ContiguousArray((0..<H.laneCount).map { $0 == 1 ? -0.0 : Float16(0) })

        #expect(H.allBitsClear(H.load(from: negativeZeros.span)) == comparesAsFloat16)
        #expect(H.allBitsClear(H.load(from: oneNegativeZero.span)) == comparesAsFloat16)
        #expect(H.allBitsClear(H.zero()))
    }

    @Test("The bit pattern of a constant vector keeps the sign of every zero lane")
    func bitPatternOfSignedZeros() {
        var vector = SIMDFloat16.zero()
        for lane in 0..<SIMDFloat16.laneCount where lane % 2 == 1 {
            vector[lane] = -0.0
        }

        #expect(
            lanes(SIMDUInt16.self, SIMDUInt16.vector(bitPattern: vector))
                == (0..<SIMDFloat16.laneCount).map { $0 % 2 == 1 ? 0x8000 : 0 }
        )
    }
}
#endif
