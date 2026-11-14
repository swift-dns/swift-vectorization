import CHighwayReference
package import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package var assertionsAreEnabled: Bool {
    _isDebugAssertConfiguration() || HighwayReference.hasDebugAssertions()
}

package var isAmd64: Bool {
    #if arch(x86_64)
    true
    #else
    false
    #endif
}

package var isDarwin: Bool {
    #if canImport(Darwin)
    true
    #else
    false
    #endif
}

@usableFromInline
package struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    @usableFromInline
    package init(seed: UInt64) {
        state = seed
    }

    @usableFromInline
    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed &>> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed &>> 31)
    }
}

@usableFromInline
package protocol ReferenceLane: Hashable, Codable {
    associatedtype Bits: FixedWidthInteger & UnsignedInteger

    var bits: Bits { get }
    static var edges: [Self] { get }
    static var conversionEdges: [Self] { get }
    static func random(using generator: inout SplitMix64) -> Self
}

extension ReferenceLane where Self: FixedWidthInteger {
    @usableFromInline
    package var bits: Bits { Bits(truncatingIfNeeded: self) }

    @usableFromInline
    package static var edges: [Self] {
        let candidates: [Self] = [
            0, 1, 2, 3, .max / 2, .max / 2 + 1, .max - 1, .max, .min, .min + 1,
        ]
        return candidates.reduce(into: []) { unique, value in
            if !unique.contains(value) {
                unique.append(value)
            }
        }
    }

    @usableFromInline
    package static var conversionEdges: [Self] {
        var unique: [Self] = []
        for width in [8, 16, 24, 32, 53] where width < bitWidth {
            for limit in [1 << (width - 1), 1 << width] {
                for offset in [-1, 0, 1] {
                    for candidate in [limit + offset, -limit + offset] {
                        let edge = Self(truncatingIfNeeded: candidate)
                        if !unique.contains(edge) {
                            unique.append(edge)
                        }
                    }
                }
            }
        }
        let edge = Self(truncatingIfNeeded: -1024)
        if !unique.contains(edge) {
            unique.append(edge)
        }
        return unique
    }

    @usableFromInline
    package static func random(using generator: inout SplitMix64) -> Self {
        Self(truncatingIfNeeded: generator.next())
    }
}

extension ReferenceLane where Self: BinaryFloatingPoint, Self.Exponent == Int {
    @usableFromInline
    package static var conversionEdges: [Self] {
        func power(_ exponent: Int) -> Self {
            Self(sign: .plus, exponent: exponent, significand: 1)
        }
        let precision = significandBitCount
        var positive: [Self] = [
            power(precision - 1) + 0.5, power(precision) - 0.5, power(precision),
            power(precision) + 1, power(precision + 1),
        ]
        for tie: Self in [0.5, 1, 1.5, 2.5, 3.5] {
            positive += [tie, tie.nextDown, tie.nextUp]
        }
        for exponent in [31, 32, 63, 64] {
            positive += [power(exponent), power(exponent).nextDown, power(exponent).nextUp]
        }
        return positive + positive.map { -$0 }
    }
}

extension UInt8: ReferenceLane { @usableFromInline package typealias Bits = UInt8 }
extension UInt16: ReferenceLane { @usableFromInline package typealias Bits = UInt16 }
extension UInt32: ReferenceLane { @usableFromInline package typealias Bits = UInt32 }
extension UInt64: ReferenceLane { @usableFromInline package typealias Bits = UInt64 }
extension Int8: ReferenceLane { @usableFromInline package typealias Bits = UInt8 }
extension Int16: ReferenceLane { @usableFromInline package typealias Bits = UInt16 }
extension Int32: ReferenceLane { @usableFromInline package typealias Bits = UInt32 }
extension Int64: ReferenceLane { @usableFromInline package typealias Bits = UInt64 }

extension Float: ReferenceLane {
    @usableFromInline
    package var bits: UInt32 { bitPattern }

    @usableFromInline
    package static var edges: [Float] {
        let limits: [Float] = [0x1p31, 0x1p32, 0x1p63, 0x1p64]
        return [
            0, -0.0, 1, -1, 0.5, -0.5, 1.5, 2.5, -2.5, .ulpOfOne, .infinity, -.infinity,
            .nan, -.nan, .signalingNaN, Float(nan: 1, signaling: false), .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude,
        ]
            + limits.flatMap { limit in
                [limit, limit.nextDown, limit.nextUp, -limit, (-limit).nextDown, (-limit).nextUp]
            }
    }

    @usableFromInline
    package static func random(using generator: inout SplitMix64) -> Float {
        let raw = generator.next()
        guard raw & 3 != 0 else { return Float(bitPattern: UInt32(truncatingIfNeeded: raw >> 32)) }
        return Float(Int32(truncatingIfNeeded: raw >> 32) % 1_000_000) / 1000
    }
}

extension Double: ReferenceLane {
    @usableFromInline
    package var bits: UInt64 { bitPattern }

    @usableFromInline
    package static var edges: [Double] {
        [
            0, -0.0, 1, -1, 0.5, -0.5, 1.5, 2.5, -2.5, .ulpOfOne, .infinity, -.infinity,
            .nan, -.nan, .signalingNaN, Double(nan: 1, signaling: false), .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude,
        ]
    }

    @usableFromInline
    package static func random(using generator: inout SplitMix64) -> Double {
        let raw = generator.next()
        guard raw & 3 != 0 else { return Double(bitPattern: generator.next()) }
        return Double(Int64(truncatingIfNeeded: raw) % 1_000_000_000) / 1_000_000
    }
}

package protocol ReferenceVector {
    associatedtype Simd: SIMD where Simd.Scalar: ReferenceLane
    associatedtype InputLane: ReferenceLane = Simd.Scalar

    init(_ simd: Simd)
    var simd: Simd { get }

    static func simdLane(_ lane: InputLane) -> Simd.Scalar
}

extension ReferenceVector where InputLane == Simd.Scalar {
    package static func simdLane(_ lane: InputLane) -> Simd.Scalar { lane }
}

package protocol ReferenceNarrowVector {
    associatedtype Lane: ReferenceLane
    associatedtype Raw

    static var laneCount: Int { get }

    var raw: Raw { get set }

    init(lanes: [Lane])
    var lanes: [Lane] { get }
}

package protocol ReferenceNarrowMask {
    associatedtype Lane: ReferenceLane & FixedWidthInteger & SignedInteger
    associatedtype Raw: BitwiseCopyable

    static var laneCount: Int { get }

    init(raw: Raw)
    var raw: Raw { get }
}

extension ReferenceNarrowMask {
    package init(lanes: [Lane], padding: Lane) {
        let registerLanes = MemoryLayout<Raw>.size / MemoryLayout<Lane>.size
        let register = lanes + [Lane](repeating: padding, count: registerLanes - lanes.count)
        self.init(raw: register.withUnsafeBytes { unsafe $0.loadUnaligned(as: Raw.self) })
    }

    package var lanes: [Lane] {
        withUnsafeBytes(of: raw) { bytes in
            (0..<Self.laneCount).map {
                unsafe bytes.loadUnaligned(
                    fromByteOffset: $0 * MemoryLayout<Lane>.size,
                    as: Lane.self
                )
            }
        }
    }
}

package protocol ReferenceMask {
    associatedtype Storage: SIMD
    where Storage.Scalar: ReferenceLane & FixedWidthInteger & SignedInteger

    init(_ simd: SIMDMask<Storage>)
    var simd: SIMDMask<Storage> { get }
}

package enum Inputs {
    package static let randomCount = 64

    package static func lanes<Lane: ReferenceLane>(_ type: Lane.Type, seed: UInt64) -> [Lane] {
        var generator = SplitMix64(seed: seed)
        return Lane.edges + (0..<(4 * randomCount)).map { _ in Lane.random(using: &generator) }
    }

    package static func vectorLanes<Lane: ReferenceLane>(
        _ type: Lane.Type,
        count: Int,
        seed: UInt64
    ) -> [[Lane]] {
        var generator = SplitMix64(seed: seed)
        let edges = Lane.edges
        let splats = edges.map { Array(repeating: $0, count: count) }
        let rotations = edges.indices.map { offset in
            (0..<count).map { edges[($0 + offset) % edges.count] }
        }
        let random = (0..<randomCount).map { _ in
            (0..<count).map { _ in Lane.random(using: &generator) }
        }
        let numbers = edges.filter { $0 == $0 }
        let nans = edges.filter { $0 != $0 }
        let lonelyNaNs: [[Lane]] =
            nans.isEmpty
            ? []
            : (0..<count).map { lane in
                var lanes = (0..<count).map { numbers[($0 + lane) % numbers.count] }
                lanes[lane] = nans[lane % nans.count]
                return lanes
            }
        return splats + rotations + random + lonelyNaNs
    }

    package static func conversionLanes<Lane: ReferenceLane>(
        _ type: Lane.Type,
        count: Int,
        seed: UInt64
    ) -> [[Lane]] {
        let edges = Lane.conversionEdges
        let splats = edges.map { Array(repeating: $0, count: count) }
        let rotations = edges.indices.map { offset in
            (0..<count).map { edges[($0 + offset) % edges.count] }
        }
        return vectorLanes(type, count: count, seed: seed) + splats + rotations
    }

    package static func integerDemotionLanes<Lane: ReferenceLane & FixedWidthInteger>(
        _ type: Lane.Type,
        count: Int,
        resultBits: Int,
        resultIsSigned: Bool,
        seed: UInt64
    ) -> [[Lane]] {
        var edges: [Lane] = []
        func add(_ value: Lane) {
            if !edges.contains(value) {
                edges.append(value)
            }
        }
        for value in [0, 1, ~0] as [Lane] {
            add(value)
        }
        for shift in 0..<Lane.bitWidth {
            let top = resultBits - (resultIsSigned ? 1 : 0) + shift
            guard top < Lane.bitWidth else { break }
            let half: Lane = shift > 0 ? 1 &<< (shift - 1) : 0
            let upper: Lane = 1 &<< top
            let lower: Lane = resultIsSigned ? 0 &- upper : 0
            for base in [upper, lower] {
                for offset in [0, -1, 0 &- half, 0 &- half &- 1] as [Lane] {
                    add(base &+ offset)
                }
            }
        }
        let rotations = edges.indices.map { offset in
            (0..<count).map { edges[($0 + offset) % edges.count] }
        }
        return conversionLanes(type, count: count, seed: seed) + rotations
    }

    package static func integerDemotions<V: ReferenceVector, Result: FixedWidthInteger>(
        _ type: V.Type,
        to result: Result.Type,
        seed: UInt64
    ) -> [V] where V.Simd.Scalar: ReferenceLane & FixedWidthInteger {
        integerDemotionLanes(
            V.Simd.Scalar.self,
            count: V.Simd.scalarCount,
            resultBits: Result.bitWidth,
            resultIsSigned: Result.isSigned,
            seed: seed
        ).map { V(V.Simd($0)) }
    }

    package static func vectors<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane {
        vectorLanes(V.Scalar.self, count: V.scalarCount, seed: seed).map { V($0) }
    }

    package static func vectors<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V] {
        vectorLanes(V.InputLane.self, count: V.Simd.scalarCount, seed: seed).map {
            V(V.Simd($0.map(V.simdLane)))
        }
    }

    package static func vectors<V: ReferenceNarrowVector>(_ type: V.Type, seed: UInt64) -> [V] {
        vectorLanes(V.Lane.self, count: V.laneCount, seed: seed).map { V(lanes: $0) }
    }

    package static func conversions<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane {
        conversionLanes(V.Scalar.self, count: V.scalarCount, seed: seed).map { V($0) }
    }

    package static func conversions<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V] {
        conversionLanes(V.InputLane.self, count: V.Simd.scalarCount, seed: seed).map {
            V(V.Simd($0.map(V.simdLane)))
        }
    }

    package static func conversions<V: ReferenceNarrowVector>(_ type: V.Type, seed: UInt64) -> [V] {
        conversionLanes(V.Lane.self, count: V.laneCount, seed: seed).map { V(lanes: $0) }
    }

    package static func masks<M: ReferenceMask>(_ type: M.Type, seed: UInt64) -> [M] {
        masks(SIMDMask<M.Storage>.self, seed: seed).map(M.init)
    }

    package static func masksAndComplements<M: ReferenceMask>(_ type: M.Type, seed: UInt64) -> [M] {
        masks(SIMDMask<M.Storage>.self, seed: seed).flatMap { [M($0), M(.!$0)] }
    }

    package static func masks<M: ReferenceNarrowMask>(_ type: M.Type, seed: UInt64) -> [M] {
        var generator = SplitMix64(seed: seed)
        let lanes = M.laneCount
        let single = (0..<lanes).map { lane in
            (0..<lanes).map { $0 == lane ? M.Lane(-1) : 0 }
        }
        let random = (0..<randomCount).map { _ in
            (0..<lanes).map { _ in generator.next() & 1 == 1 ? M.Lane(-1) : 0 }
        }
        let patterns =
            [[M.Lane](repeating: 0, count: lanes), [M.Lane](repeating: -1, count: lanes)]
            + single + random
        return patterns.flatMap { pattern in
            [M.Lane(0), M.Lane(-1)].map { M(lanes: pattern, padding: $0) }
        }
    }

    package static func masks<Storage>(
        _ type: SIMDMask<Storage>.Type,
        seed: UInt64
    ) -> [SIMDMask<Storage>] {
        var generator = SplitMix64(seed: seed)
        let lanes = Storage.scalarCount
        let single = (0..<lanes).map { lane in
            var mask = SIMDMask<Storage>(repeating: false)
            mask[lane] = true
            return mask
        }
        let random = (0..<randomCount).map { _ in
            var mask = SIMDMask<Storage>(repeating: false)
            for lane in 0..<lanes {
                mask[lane] = generator.next() & 1 == 1
            }
            return mask
        }
        return [SIMDMask(repeating: false), SIMDMask(repeating: true)] + single + random
    }

    package static func nonCanonicalMasks<M: ReferenceMask>(_ type: M.Type, seed: UInt64) -> [M] {
        nonCanonicalMaskLanes(M.Storage.Scalar.self, count: M.Storage.scalarCount, seed: seed).map {
            M(SIMDMask(M.Storage($0)))
        }
    }

    package static func nonCanonicalMasks<M: ReferenceNarrowMask>(
        _ type: M.Type,
        seed: UInt64
    ) -> [M] {
        nonCanonicalMaskLanes(M.Lane.self, count: M.laneCount, seed: seed).flatMap { lanes in
            [M.Lane(0), M.Lane(-1)].map { M(lanes: lanes, padding: $0) }
        }
    }

    package static func nonCanonicalMaskLanes<Lane: FixedWidthInteger & SignedInteger>(
        _ type: Lane.Type,
        count: Int,
        seed: UInt64
    ) -> [[Lane]] {
        var generator = SplitMix64(seed: seed)
        let middle =
            Lane(truncatingIfNeeded: UInt64.max >> (64 - Lane.bitWidth / 2)) << (Lane.bitWidth / 4)
        let patterns: [Lane] = [0, -1, .min, 1, middle, .max]
        let splats = patterns.map { Array(repeating: $0, count: count) }
        let rotations = patterns.indices.map { offset in
            (0..<count).map { patterns[($0 + offset) % patterns.count] }
        }
        let mixed = (0..<randomCount).map { _ in
            (0..<count).map { _ in patterns[Int(generator.next() % UInt64(patterns.count))] }
        }
        let random = (0..<randomCount / 4).map { _ in
            (0..<count).map { _ in Lane(truncatingIfNeeded: generator.next()) }
        }
        return splats + rotations + mixed + random
    }

    package static func maskBits(lanes: Int, seed: UInt64) -> [UInt] {
        var generator = SplitMix64(seed: seed)
        let limit = UInt(1) << UInt(lanes)
        let inRange: [UInt] =
            lanes <= 8
            ? Array(0..<limit)
            : [0, 1, limit - 1, 0x5555 & (limit - 1), 0xAAAA & (limit - 1)]
                + (0..<4 * randomCount).map { _ in
                    UInt(truncatingIfNeeded: generator.next()) & (limit - 1)
                }
        let beyond: [UInt] = [
            limit, limit + 1, limit | 5, .max, UInt(UInt32.max), UInt(1) << 32, (UInt(1) << 32) | 5,
            UInt(1) << 63,
        ]
        let random = (0..<randomCount).map { _ in UInt(truncatingIfNeeded: generator.next()) }
        return inRange + beyond + random
    }

    package static func buffers<Lane: ReferenceLane>(
        _ type: Lane.Type,
        count: Int,
        seed: UInt64
    ) -> [[Lane]] {
        var generator = SplitMix64(seed: seed)
        let edges = Lane.edges
        let rotations = edges.indices.map { offset in
            (0..<count).map { edges[($0 + offset) % edges.count] }
        }
        let random = (0..<randomCount).map { _ in
            (0..<count).map { _ in Lane.random(using: &generator) }
        }
        return rotations + random
    }

    package static func indexBuffers<Lane: FixedWidthInteger>(
        _ type: Lane.Type,
        lanes: Int,
        seed: UInt64
    ) -> [[Lane]] {
        indexLanes(type, lanes: lanes, offset: 0, count: lanes, seed: seed, inContract: true)
    }

    package static func byteBuffers(count: Int, seed: UInt64) -> [[UInt8]] {
        var generator = SplitMix64(seed: seed)
        let digits = Array(UInt8(ascii: "0")...UInt8(ascii: "9"))
        let lowercase = Array(UInt8(ascii: "a")...UInt8(ascii: "z"))
        let uppercase = Array(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        let alphabets = [
            digits, lowercase, uppercase, digits + lowercase, digits + lowercase + uppercase,
            Array(0...0x7F), Array(0...0xFF),
        ]
        let texts = alphabets.flatMap { alphabet in
            (0..<(randomCount / 4)).map { _ in
                (0..<count).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
            }
        }
        let scalarRanges: [ClosedRange<UInt32>] = [
            0...0x7F, 0x80...0x7FF, 0x800...0xD7FF, 0xE000...0xFFFF, 0x1_0000...0x10_FFFF,
        ]
        let encodings = (0..<(randomCount / 4)).map { _ in
            var bytes: [UInt8] = []
            while bytes.count < count {
                let range = scalarRanges[Int(generator.next() % UInt64(scalarRanges.count))]
                let value = range.lowerBound + UInt32(generator.next() % UInt64(range.count))
                bytes += Array(String(Unicode.Scalar(value)!).utf8)
            }
            return Array(bytes.prefix(count))
        }
        let corruptions = encodings.map { encoding in
            var corrupted = encoding
            let index = Int(generator.next() % UInt64(count))
            corrupted[index] = UInt8(truncatingIfNeeded: generator.next())
            return corrupted
        }
        return buffers(UInt8.self, count: count, seed: seed) + texts + encodings + corruptions
    }

    package static func sentinel<Lane: ReferenceLane>(_ type: Lane.Type, count: Int) -> [Lane] {
        let edges = Lane.edges
        return (0..<count).map { edges[($0 * 7 + 3) % edges.count] }
    }

    private static func indexLanes<Lane: FixedWidthInteger>(
        _ type: Lane.Type,
        lanes laneCount: Int,
        offset: Int,
        count: Int,
        seed: UInt64,
        inContract: Bool
    ) -> [[Lane]] {
        var generator = SplitMix64(seed: seed)
        func lane(_ index: Int) -> Lane { Lane(truncatingIfNeeded: offset + index) }
        func inRange() -> Lane { lane(Int(generator.next() % UInt64(count))) }
        let identity = (0..<laneCount).map { lane($0 % count) }
        guard !inContract else {
            let random = (0..<randomCount).map { _ in (0..<laneCount).map { _ in inRange() } }
            return [identity] + random
        }
        let beyond = [lane(count), lane(count + 1), lane(2 * count), lane(-1), Lane.min, .max]
        let splats = beyond.map { Array(repeating: $0, count: laneCount) }
        let random = (0..<randomCount).map { _ in
            (0..<laneCount).map { _ in
                switch generator.next() % 4 {
                case 0: Lane(truncatingIfNeeded: generator.next())
                case 1: lane(count + Int(generator.next() % UInt64(count)))
                case 2: lane(-1 - Int(generator.next() % UInt64(count)))
                default: inRange()
                }
            }
        }
        return [identity] + splats + random
    }

    package static func tableIndices<V: SIMD>(
        _ type: V.Type,
        offset: Int = 0,
        perByte: Bool = false,
        count: Int,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Scalar: ReferenceLane & FixedWidthInteger {
        guard perByte else {
            return indexLanes(
                V.Scalar.self,
                lanes: V.scalarCount,
                offset: offset,
                count: count,
                seed: seed,
                inContract: inContract
            ).map { V($0) }
        }
        return byteIndices(V.self, offset: offset, count: count, seed: seed, inContract: inContract)
    }

    package static func tableIndices<V: SIMD>(
        _ type: V.Type,
        offset: Int = 0,
        perByte: Bool,
        count: Int,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Scalar: ReferenceLane & BinaryFloatingPoint {
        precondition(perByte, "Floating-point lanes only take byte indices")
        return byteIndices(V.self, offset: offset, count: count, seed: seed, inContract: inContract)
    }

    private static func byteIndices<V: SIMD>(
        _ type: V.Type,
        offset: Int,
        count: Int,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Scalar: ReferenceLane {
        let size = MemoryLayout<V.Scalar>.size
        return indexLanes(
            UInt8.self,
            lanes: V.scalarCount * size,
            offset: offset,
            count: count,
            seed: seed,
            inContract: inContract
        ).map { bytes in
            bytes.withUnsafeBytes { raw in
                V(
                    (0..<V.scalarCount).map {
                        unsafe raw.loadUnaligned(fromByteOffset: $0 * size, as: V.Scalar.self)
                    }
                )
            }
        }
    }

    package static func tableIndices<V: ReferenceVector>(
        _ type: V.Type,
        offset: Int = 0,
        perByte: Bool = false,
        count: Int,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Simd.Scalar: FixedWidthInteger {
        tableIndices(
            V.Simd.self,
            offset: offset,
            perByte: perByte,
            count: count,
            seed: seed,
            inContract: inContract
        ).map(V.init)
    }

    package static func shiftAmounts(bits: Int, inContract: Bool) -> [Int] {
        guard !inContract else { return Array(0..<bits) }
        let candidates = [
            bits, bits + 1, 2 * bits, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256, -1, -2, -bits,
            Int(Int32.max), Int(Int32.min),
        ]
        return candidates.reduce(into: []) { unique, amount in
            if (amount < 0 || amount >= bits) && !unique.contains(amount) {
                unique.append(amount)
            }
        }
    }

    package static func shiftCounts<V: SIMD>(
        _ type: V.Type,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Scalar: ReferenceLane & FixedWidthInteger {
        var generator = SplitMix64(seed: seed)
        let bits = V.Scalar.bitWidth
        func lane(_ amount: Int) -> V.Scalar { V.Scalar(truncatingIfNeeded: amount) }
        func inRange() -> V.Scalar { lane(Int(generator.next() % UInt64(bits))) }
        let amounts = inContract ? Array(0..<bits) : shiftAmounts(bits: bits, inContract: false)
        let splats = amounts.map { V(repeating: lane($0)) }
        let rotations = amounts.indices.map { offset in
            V((0..<V.scalarCount).map { lane(amounts[($0 + offset) % amounts.count]) })
        }
        let random = (0..<randomCount).map { _ in
            V(
                (0..<V.scalarCount).map { _ in
                    guard !inContract else { return inRange() }
                    switch generator.next() % 4 {
                    case 0: return V.Scalar(truncatingIfNeeded: generator.next())
                    case 1: return lane(amounts[Int(generator.next() % UInt64(amounts.count))])
                    default: return inRange()
                    }
                }
            )
        }
        return splats + rotations + random
    }

    package static func shiftCounts<V: ReferenceVector>(
        _ type: V.Type,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Simd.Scalar: FixedWidthInteger {
        shiftCounts(V.Simd.self, seed: seed, inContract: inContract).map(V.init)
    }

    package static func counts(through limit: Int) -> [Int] {
        Array(0...limit)
    }

    package static func laneAmounts(lanes: Int, inContract: Bool) -> [Int] {
        inContract ? Array(0..<lanes) : [lanes]
    }

    package static func laneIndices(lanes: Int) -> [Int] {
        Array(0..<lanes)
    }

    package static func tupleIndices(count: Int) -> [Int] {
        Array(0..<count)
    }

    package static func tuples2<V>(of vectors: [V]) -> [(V, V)] {
        vectors.indices.map { (vectors[$0], vectors[($0 + 1) % vectors.count]) }
    }

    package static func tuples3<V>(of vectors: [V]) -> [(V, V, V)] {
        vectors.indices.map {
            (vectors[$0], vectors[($0 + 1) % vectors.count], vectors[($0 + 2) % vectors.count])
        }
    }

    package static func tuples4<V>(of vectors: [V]) -> [(V, V, V, V)] {
        vectors.indices.map {
            (
                vectors[$0], vectors[($0 + 1) % vectors.count], vectors[($0 + 2) % vectors.count],
                vectors[($0 + 3) % vectors.count]
            )
        }
    }

    package static func countsBeyond32Bits(lanes: Int) -> [Int] {
        [1 << 32, (1 << 32) + 1, (1 << 32) + lanes]
    }

    package static func bufferCounts(lanes: Int) -> [Int] {
        Array(0...(lanes + 1)) + [2 * lanes, 1000] + countsBeyond32Bits(lanes: lanes)
    }

    package static func maskCounts<Lane: FixedWidthInteger>(lanes: Int, lane: Lane.Type) -> [Int] {
        let limit = Lane.bitWidth >= Int.bitWidth ? Int.max : (1 << (Lane.bitWidth - 1)) - 1
        let beyond32Bits = countsBeyond32Bits(lanes: lanes).filter { $0 <= limit }
        return Array(0...(lanes + 1)) + [limit] + beyond32Bits
    }
}

@inlinable
package func everyPair<A, B>(_ first: [A], _ second: [B]) -> [(A, B)] {
    first.flatMap { a in second.map { b in (a, b) } }
}

@inlinable
package func mixedTriples<A, B, C>(
    _ first: [A],
    _ second: [B],
    _ third: [C],
    seed: UInt64
) -> [(A, B, C)] {
    var generator = SplitMix64(seed: seed)
    return everyPair(first, second).map { a, b in
        (a, b, third[Int(generator.next() % UInt64(third.count))])
    }
}

@inlinable
package func mixedQuadruples<A, B, C, D>(
    _ first: [A],
    _ second: [B],
    _ third: [C],
    _ fourth: [D],
    seed: UInt64
) -> [(A, B, C, D)] {
    var generator = SplitMix64(seed: seed)
    return everyPair(first, second).map { a, b in
        (
            a, b, third[Int(generator.next() % UInt64(third.count))],
            fourth[Int(generator.next() % UInt64(fourth.count))]
        )
    }
}

@inlinable
package func mixedQuintuples<A, B, C, D, E>(
    _ first: [A],
    _ second: [B],
    _ third: [C],
    _ fourth: [D],
    _ fifth: [E],
    seed: UInt64
) -> [(A, B, C, D, E)] {
    var generator = SplitMix64(seed: seed)
    return everyPair(first, second).map { a, b in
        (
            a, b, third[Int(generator.next() % UInt64(third.count))],
            fourth[Int(generator.next() % UInt64(fourth.count))],
            fifth[Int(generator.next() % UInt64(fifth.count))]
        )
    }
}

package func poisoned<Indices: ReferenceVector, Mask: ReferenceMask>(
    _ indices: Indices,
    where mask: Mask,
    with poison: Int
) -> Indices where Indices.Simd.Scalar: FixedWidthInteger {
    var lanes = indices.simd
    for lane in 0..<Indices.Simd.scalarCount where mask.simd._storage[lane] == 0 {
        lanes[lane] = Indices.Simd.Scalar(truncatingIfNeeded: poison)
    }
    return Indices(lanes)
}

package func hasAllOnesLane<M: ReferenceMask>(_ mask: M) -> Bool {
    (0..<M.Storage.scalarCount).contains { mask.simd._storage[$0] == -1 }
}

package func poisoned<Indices: ReferenceVector>(
    _ indices: Indices,
    firstLanes count: Int,
    with poison: Int
) -> Indices where Indices.Simd.Scalar: FixedWidthInteger {
    var lanes = indices.simd
    for lane in 0..<Indices.Simd.scalarCount where lane >= count {
        lanes[lane] = Indices.Simd.Scalar(truncatingIfNeeded: poison)
    }
    return Indices(lanes)
}

package func compressedLaneCount(bits: [UInt8], lanes: Int, tailIsDeterministic: Bool) -> Int {
    tailIsDeterministic
        ? lanes : (0..<lanes).filter { bits[$0 / 8] >> UInt8($0 % 8) & 1 == 1 }.count
}

package func withAlignedLanes<Lane: ReferenceLane, Result>(
    _ lanes: [Lane],
    laneCount: Int,
    _ body: (UnsafeMutablePointer<Lane>) -> Result
) -> (result: Result, lanes: [Lane]) {
    let byteCount = max(lanes.count, 1) * MemoryLayout<Lane>.stride
    let alignment = laneCount * MemoryLayout<Lane>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
    defer { unsafe raw.deallocate() }
    let pointer = unsafe raw.initializeMemory(as: Lane.self, from: lanes, count: lanes.count)
    let result = unsafe body(pointer)
    return (result, unsafe Array(UnsafeBufferPointer(start: pointer, count: lanes.count)))
}

package func withOutputSpan<Lane: ReferenceLane, Result>(
    capacity: Int,
    alignment: Int = MemoryLayout<Lane>.alignment,
    _ body: (inout OutputSpan<Lane>) -> Result
) -> (result: Result, lanes: [Lane]) {
    let sentinel = Inputs.sentinel(Lane.self, count: capacity + 4)
    let buffer =
        unsafe UnsafeMutableRawBufferPointer
        .allocate(byteCount: sentinel.count * MemoryLayout<Lane>.stride, alignment: alignment)
        .bindMemory(to: Lane.self)
    defer { unsafe buffer.deallocate() }
    _ = unsafe buffer.initialize(from: sentinel)
    let region = unsafe UnsafeMutableBufferPointer(rebasing: buffer[0..<capacity])
    var output = unsafe OutputSpan(buffer: region, initializedCount: 0)
    let result = body(&output)
    _ = unsafe output.finalize(for: region)
    return (result, unsafe Array(buffer))
}

package func withMutableSpan<Lane: ReferenceLane, Result>(
    of lanes: [Lane],
    _ body: (inout MutableSpan<Lane>) -> Result
) -> (result: Result, lanes: [Lane]) {
    let sentinel = Inputs.sentinel(Lane.self, count: 4)
    let buffer = UnsafeMutableBufferPointer<Lane>.allocate(capacity: lanes.count + sentinel.count)
    defer { unsafe buffer.deallocate() }
    _ = unsafe buffer.initialize(from: lanes + sentinel)
    let region = unsafe UnsafeMutableBufferPointer(rebasing: buffer[0..<lanes.count])
    var span = unsafe region.mutableSpan
    let result = body(&span)
    return (result, unsafe Array(buffer))
}

package func withGuardedLanes<Lane: ReferenceLane, Result>(
    _ lanes: [Lane],
    _ body: (UnsafeMutablePointer<Lane>) -> Result
) -> (result: Result, lanes: [Lane]) {
    let pageSize = Int(getpagesize())
    let byteCount = lanes.count * MemoryLayout<Lane>.stride
    precondition(byteCount <= pageSize, "\(byteCount) bytes do not fit before a guard page")
    let protection = PROT_READ | PROT_WRITE
    let flags = MAP_PRIVATE | MAP_ANONYMOUS
    guard let pages = unsafe mmap(nil, 2 * pageSize, protection, flags, -1, 0),
        unsafe pages != UnsafeMutableRawPointer(bitPattern: -1)
    else {
        fatalError("Failed to map the pages around a guard page")
    }
    defer { unsafe munmap(pages, 2 * pageSize) }
    let guardPage = unsafe pages + pageSize
    precondition(unsafe mprotect(guardPage, pageSize, PROT_NONE) == 0, "Failed to protect a page")
    let pointer = unsafe (guardPage - byteCount).bindMemory(to: Lane.self, capacity: lanes.count)
    unsafe pointer.initialize(from: lanes, count: lanes.count)
    let result = unsafe body(pointer)
    return (result, unsafe Array(UnsafeBufferPointer(start: pointer, count: lanes.count)))
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(_ operands: V...) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    (0..<V.scalarCount).contains { lane in
        operands.contains { first in
            first[lane].isNaN
                && operands.contains { $0[lane].isNaN && $0[lane].bits != first[lane].bits }
        }
    }
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(multiplying a: V, _ b: V, adding c: V) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    (0..<V.scalarCount).contains { lane in
        let (first, second, addend) = (a[lane], b[lane], c[lane])
        let hasInvalidProduct =
            (first.isInfinite && second == 0) || (second.isInfinite && first == 0)
        let multiplicandsDiffer = first.isNaN && second.isNaN && first.bits != second.bits
        let productMeetsAddend =
            addend.isNaN && (first.isNaN || second.isNaN || hasInvalidProduct)
        return multiplicandsDiffer || productMeetsAddend
    }
}

@inlinable
package func hasNaNs<V: SIMD>(negating operands: V...) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    HighwayReference.hasNativeFusedMultiplyAdd()
        && operands.contains { operand in (0..<V.scalarCount).contains { operand[$0].isNaN } }
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(negating a: V, _ b: V, adding c: V) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    hasNaNs(negating: a, b) || hasUnorderedNaNs(multiplying: a, b, adding: c)
}

@inlinable
package func negatedLanes<V: SIMD>(of vector: V) -> V
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    V((0..<V.scalarCount).map { -vector[$0] })
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(alternatingNegation a: V, _ b: V) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    (0..<V.scalarCount).contains { lane in
        let second = lane.isMultiple(of: 2) ? -b[lane] : b[lane]
        return a[lane].isNaN && second.isNaN && a[lane].bits != second.bits
    }
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(adjacentLanesOf operands: V...) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    operands.contains { operand in
        stride(from: 0, to: V.scalarCount, by: 2).contains { lane in
            let (first, second) = (operand[lane], operand[lane + 1])
            return first.isNaN && second.isNaN && first.bits != second.bits
        }
    }
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(adjacentQuadsOf operands: V...) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint & SIMDScalar {
    operands.contains { operand in
        stride(from: 0, to: V.scalarCount, by: 4).contains { lane in
            hasUnorderedNaNs(lanesOf: SIMD4((0..<4).map { operand[lane + $0] }))
        }
    }
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(complexLanesOf operands: V...) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    let large = V.Scalar.greatestFiniteMagnitude.squareRoot() / 4
    return stride(from: 0, to: V.scalarCount, by: 2).contains { lane in
        func anyLane(_ predicate: (V.Scalar) -> Bool) -> Bool {
            operands.contains { predicate($0[lane]) || predicate($0[lane + 1]) }
        }
        let hasPayloads = anyLane { $0.isNaN }
        let payloadsDiffer = anyLane { first in
            first.isNaN && anyLane { $0.isNaN && $0.bits != first.bits }
        }
        let mayGenerateNaN = anyLane { !$0.isFinite || $0.magnitude >= large }
        return payloadsDiffer || (hasPayloads && mayGenerateNaN)
    }
}

@inlinable
package func hasUnorderedNaNs<V: SIMD>(lanesOf vector: V) -> Bool
where V.Scalar: ReferenceLane & BinaryFloatingPoint {
    let lanes = (0..<V.scalarCount).map { vector[$0] }
    let payloads = Set(lanes.filter { $0.isNaN }.map { $0.bits })
    let hasOppositeInfinities = lanes.contains(.infinity) && lanes.contains(-.infinity)
    return payloads.count > 1 || (!payloads.isEmpty && hasOppositeInfinities)
}

package func hex<Lane: ReferenceLane>(_ lane: Lane) -> String {
    "0x" + String(lane.bits, radix: 16)
}

package func describe<V: SIMD>(_ vector: V) -> String where V.Scalar: ReferenceLane {
    "[" + (0..<V.scalarCount).map { hex(vector[$0]) }.joined(separator: ", ") + "]"
}

package func describe<Storage>(_ mask: SIMDMask<Storage>) -> String
where Storage.Scalar: ReferenceLane {
    describe(mask._storage)
}

package func describe<V: ReferenceVector>(_ vector: V) -> String {
    describe(vector.simd)
}

package func describe<M: ReferenceMask>(_ mask: M) -> String {
    describe(mask.simd)
}

package func describe<V: ReferenceNarrowVector>(_ vector: V) -> String {
    describe(vector.lanes)
}

package func describe<M: ReferenceNarrowMask>(_ mask: M) -> String {
    describe(mask.lanes)
}

package func describe<Lane: ReferenceLane>(_ lanes: [Lane]) -> String {
    "[" + lanes.map(hex).joined(separator: ", ") + "]"
}

package func bytes<Lane: ReferenceLane>(of lanes: [Lane]) -> [UInt8] {
    lanes.flatMap { lane in
        (0..<MemoryLayout<Lane>.size).map { UInt8(truncatingIfNeeded: lane.bits &>> (8 * $0)) }
    }
}

package func bytes<V: SIMD>(of vector: V) -> [UInt8] where V.Scalar: ReferenceLane {
    bytes(of: (0..<V.scalarCount).map { vector[$0] })
}

package func bytes<V: ReferenceVector>(of vector: V) -> [UInt8] {
    bytes(of: vector.simd)
}

package func bytes<V: ReferenceNarrowVector>(of vector: V) -> [UInt8] {
    bytes(of: vector.lanes)
}

package func registerBytes<V: SIMD>(of vector: V) -> [UInt8] where V.Scalar: ReferenceLane {
    bytes(of: vector)
}

package func registerBytes<V: ReferenceVector>(of vector: V) -> [UInt8] {
    bytes(of: vector)
}

package func registerBytes<V: ReferenceNarrowVector>(of vector: V) -> [UInt8]
where V.Raw: BitwiseCopyable {
    withUnsafeBytes(of: vector.raw) { unsafe Array($0) }
}

package func poisoningUpperBytes<V: ReferenceNarrowVector>(_ vector: V) -> V {
    var poisoned = vector
    let ownBytes = V.laneCount * MemoryLayout<V.Lane>.stride
    withUnsafeMutableBytes(of: &poisoned.raw) { raw in
        for index in ownBytes..<raw.count {
            unsafe raw[index] = 0xA5
        }
    }
    return poisoned
}

package final class Mismatches {
    private let operation: String
    private var count = 0
    private var examples: [String] = []

    package init(_ operation: String) {
        self.operation = operation
    }

    package func check<V: SIMD>(
        _ port: V,
        _ reference: V,
        _ inputs: @autoclosure () -> String
    ) where V.Scalar: ReferenceLane {
        let same = (0..<V.scalarCount).allSatisfy { port[$0].bits == reference[$0].bits }
        note(same, "port \(describe(port)), Highway \(describe(reference))", inputs)
    }

    package func check<Storage>(
        _ port: SIMDMask<Storage>,
        _ reference: SIMDMask<Storage>,
        _ inputs: @autoclosure () -> String
    ) where Storage.Scalar: ReferenceLane {
        check(port._storage, reference._storage, inputs())
    }

    package func check<V: ReferenceVector>(
        _ port: V,
        _ reference: V,
        _ inputs: @autoclosure () -> String
    ) {
        check(port.simd, reference.simd, inputs())
    }

    package func check<M: ReferenceMask>(
        _ port: M,
        _ reference: M,
        _ inputs: @autoclosure () -> String
    ) {
        check(port.simd, reference.simd, inputs())
    }

    package func check<V: ReferenceNarrowVector>(
        _ port: V,
        _ reference: V,
        _ inputs: @autoclosure () -> String
    ) {
        check(port.lanes, reference.lanes, inputs())
    }

    package func check<M: ReferenceNarrowMask>(
        _ port: M,
        _ reference: M,
        _ inputs: @autoclosure () -> String
    ) {
        check(port.lanes, reference.lanes, inputs())
    }

    package func check<Lane: ReferenceLane>(
        _ port: Lane,
        _ reference: Lane,
        _ inputs: @autoclosure () -> String
    ) {
        note(port.bits == reference.bits, "port \(hex(port)), Highway \(hex(reference))", inputs)
    }

    package func check<Lane: ReferenceLane>(
        _ port: [Lane],
        _ reference: [Lane],
        _ inputs: @autoclosure () -> String
    ) {
        let same = port.elementsEqual(reference) { $0.bits == $1.bits }
        note(same, "port \(describe(port)), Highway \(describe(reference))", inputs)
    }

    package func check(_ port: Int, _ reference: Int, _ inputs: @autoclosure () -> String) {
        note(port == reference, "port \(port), Highway \(reference)", inputs)
    }

    package func check(_ port: UInt64, _ reference: UInt64, _ inputs: @autoclosure () -> String) {
        note(port == reference, "port \(port), Highway \(reference)", inputs)
    }

    package func check(_ port: Bool, _ reference: Bool, _ inputs: @autoclosure () -> String) {
        note(port == reference, "port \(port), Highway \(reference)", inputs)
    }

    package func check(_ port: String, _ reference: String, _ inputs: @autoclosure () -> String) {
        note(port == reference, "port \(port), Highway \(reference)", inputs)
    }

    package func record(sourceLocation: SourceLocation = #_sourceLocation) {
        guard count > 0 else { return }
        let details = examples.joined(separator: "\n")
        Issue.record(
            "\(operation): \(count) mismatches with Highway, for example:\n\(details)",
            sourceLocation: sourceLocation
        )
    }

    package func record(
        knownIssue comment: Comment,
        when condition: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        withKnownIssue(comment, sourceLocation: sourceLocation) {
            record(sourceLocation: sourceLocation)
        } when: {
            condition
        }
    }

    private func note(_ same: Bool, _ results: @autoclosure () -> String, _ inputs: () -> String) {
        guard !same else { return }
        count += 1
        if examples.count < 5 {
            examples.append("  \(inputs()): \(results())")
        }
    }
}
