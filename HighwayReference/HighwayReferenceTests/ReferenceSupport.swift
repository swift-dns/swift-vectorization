import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed &>> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed &>> 31)
    }
}

protocol ReferenceLane: SIMDScalar, Hashable, Codable {
    associatedtype Bits: FixedWidthInteger & UnsignedInteger

    var bits: Bits { get }
    static var edges: [Self] { get }
    static func random(using generator: inout SplitMix64) -> Self
}

extension ReferenceLane where Self: FixedWidthInteger {
    var bits: Bits { Bits(truncatingIfNeeded: self) }

    static var edges: [Self] {
        let candidates: [Self] = [
            0, 1, 2, 3, .max / 2, .max / 2 + 1, .max - 1, .max, .min, .min + 1,
        ]
        return candidates.reduce(into: []) { unique, value in
            if !unique.contains(value) {
                unique.append(value)
            }
        }
    }

    static func random(using generator: inout SplitMix64) -> Self {
        Self(truncatingIfNeeded: generator.next())
    }
}

extension UInt8: ReferenceLane { typealias Bits = UInt8 }
extension UInt16: ReferenceLane { typealias Bits = UInt16 }
extension UInt32: ReferenceLane { typealias Bits = UInt32 }
extension UInt64: ReferenceLane { typealias Bits = UInt64 }
extension Int8: ReferenceLane { typealias Bits = UInt8 }
extension Int16: ReferenceLane { typealias Bits = UInt16 }
extension Int32: ReferenceLane { typealias Bits = UInt32 }
extension Int64: ReferenceLane { typealias Bits = UInt64 }

extension Float: ReferenceLane {
    var bits: UInt32 { bitPattern }

    static var edges: [Float] {
        [
            0, -0.0, 1, -1, 0.5, -0.5, 1.5, 2.5, -2.5, .ulpOfOne, .infinity, -.infinity,
            .nan, -.nan, .signalingNaN, Float(nan: 1, signaling: false), .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude,
        ]
    }

    static func random(using generator: inout SplitMix64) -> Float {
        let raw = generator.next()
        guard raw & 3 != 0 else { return Float(bitPattern: UInt32(truncatingIfNeeded: raw >> 32)) }
        return Float(Int32(truncatingIfNeeded: raw >> 32) % 1_000_000) / 1000
    }
}

extension Double: ReferenceLane {
    var bits: UInt64 { bitPattern }

    static var edges: [Double] {
        [
            0, -0.0, 1, -1, 0.5, -0.5, 1.5, 2.5, -2.5, .ulpOfOne, .infinity, -.infinity,
            .nan, -.nan, .signalingNaN, Double(nan: 1, signaling: false), .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude,
        ]
    }

    static func random(using generator: inout SplitMix64) -> Double {
        let raw = generator.next()
        guard raw & 3 != 0 else { return Double(bitPattern: generator.next()) }
        return Double(Int64(truncatingIfNeeded: raw) % 1_000_000_000) / 1_000_000
    }
}

protocol ReferenceVector {
    associatedtype Simd: SIMD where Simd.Scalar: ReferenceLane

    init(_ simd: Simd)
    var simd: Simd { get }
}

protocol ReferenceMask {
    associatedtype Storage: SIMD
    where Storage.Scalar: ReferenceLane & FixedWidthInteger & SignedInteger

    init(_ simd: SIMDMask<Storage>)
    var simd: SIMDMask<Storage> { get }
}

enum Inputs {
    static let randomCount = 64

    static func lanes<Lane: ReferenceLane>(_ type: Lane.Type, seed: UInt64) -> [Lane] {
        var generator = SplitMix64(seed: seed)
        return Lane.edges + (0..<(4 * randomCount)).map { _ in Lane.random(using: &generator) }
    }

    static func vectors<V: SIMD>(_ type: V.Type, seed: UInt64) -> [V]
    where V.Scalar: ReferenceLane {
        var generator = SplitMix64(seed: seed)
        let edges = V.Scalar.edges
        let splats = edges.map { V(repeating: $0) }
        let rotations = edges.indices.map { offset in
            V((0..<V.scalarCount).map { edges[($0 + offset) % edges.count] })
        }
        let random = (0..<randomCount).map { _ in
            V((0..<V.scalarCount).map { _ in V.Scalar.random(using: &generator) })
        }
        let numbers = edges.filter { $0 == $0 }
        let nans = edges.filter { $0 != $0 }
        let lonelyNaNs: [V] =
            nans.isEmpty
            ? []
            : (0..<V.scalarCount).map { lane in
                var vector = V((0..<V.scalarCount).map { numbers[($0 + lane) % numbers.count] })
                vector[lane] = nans[lane % nans.count]
                return vector
            }
        return splats + rotations + random + lonelyNaNs
    }

    static func vectors<V: ReferenceVector>(_ type: V.Type, seed: UInt64) -> [V] {
        vectors(V.Simd.self, seed: seed).map(V.init)
    }

    static func masks<M: ReferenceMask>(_ type: M.Type, seed: UInt64) -> [M] {
        masks(SIMDMask<M.Storage>.self, seed: seed).map(M.init)
    }

    static func masks<Storage>(
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

    static func buffers<Lane: ReferenceLane>(
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

    static func sentinel<Lane: ReferenceLane>(_ type: Lane.Type, count: Int) -> [Lane] {
        let edges = Lane.edges
        return (0..<count).map { edges[($0 * 7 + 3) % edges.count] }
    }

    static func tableIndices<V: SIMD>(
        _ type: V.Type,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Scalar: ReferenceLane & FixedWidthInteger {
        var generator = SplitMix64(seed: seed)
        let identity = V((0..<V.scalarCount).map { V.Scalar(truncatingIfNeeded: $0 & 15) })
        let random = (0..<randomCount).map { _ in
            V(
                (0..<V.scalarCount).map { _ in
                    let byte = generator.next() & 0xFF
                    return V.Scalar(truncatingIfNeeded: inContract ? byte & 15 : byte)
                }
            )
        }
        return [identity] + random
    }

    static func tableIndices<V: ReferenceVector>(
        _ type: V.Type,
        seed: UInt64,
        inContract: Bool
    ) -> [V] where V.Simd.Scalar: FixedWidthInteger {
        tableIndices(V.Simd.self, seed: seed, inContract: inContract).map(V.init)
    }

    static func shiftAmounts(bits: Int, inContract: Bool) -> [Int] {
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

    static func laneAmounts(lanes: Int, inContract: Bool) -> [Int] {
        inContract ? Array(0..<lanes) : [lanes]
    }

    static func bufferCounts(lanes: Int) -> [Int] {
        Array(0...(lanes + 1)) + [2 * lanes, 1000]
    }

    static func maskCounts<Lane: FixedWidthInteger>(lanes: Int, lane: Lane.Type) -> [Int] {
        let limit = Lane.bitWidth >= Int.bitWidth ? Int.max : (1 << (Lane.bitWidth - 1)) - 1
        return Array(0...(lanes + 1)) + [limit]
    }
}

func everyPair<A, B>(_ first: [A], _ second: [B]) -> [(A, B)] {
    first.flatMap { a in second.map { b in (a, b) } }
}

func mixedTriples<A, B, C>(
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

func mixedQuadruples<A, B, C, D>(
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

func withAlignedLanes<Lane: ReferenceLane, Result>(
    _ lanes: [Lane],
    _ body: (UnsafeMutablePointer<Lane>) -> Result
) -> (result: Result, lanes: [Lane]) {
    let byteCount = max(lanes.count, 1) * MemoryLayout<Lane>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    defer { unsafe raw.deallocate() }
    let pointer = unsafe raw.initializeMemory(as: Lane.self, from: lanes, count: lanes.count)
    let result = unsafe body(pointer)
    return (result, unsafe Array(UnsafeBufferPointer(start: pointer, count: lanes.count)))
}

func withGuardedLanes<Lane: ReferenceLane, Result>(
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

func hex<Lane: ReferenceLane>(_ lane: Lane) -> String {
    "0x" + String(lane.bits, radix: 16)
}

func describe<V: SIMD>(_ vector: V) -> String where V.Scalar: ReferenceLane {
    "[" + (0..<V.scalarCount).map { hex(vector[$0]) }.joined(separator: ", ") + "]"
}

func describe<Storage>(_ mask: SIMDMask<Storage>) -> String where Storage.Scalar: ReferenceLane {
    describe(mask._storage)
}

func describe<V: ReferenceVector>(_ vector: V) -> String {
    describe(vector.simd)
}

func describe<M: ReferenceMask>(_ mask: M) -> String {
    describe(mask.simd)
}

func describe<Lane: ReferenceLane>(_ lanes: [Lane]) -> String {
    "[" + lanes.map(hex).joined(separator: ", ") + "]"
}

final class Mismatches {
    private let operation: String
    private var count = 0
    private var examples: [String] = []

    init(_ operation: String) {
        self.operation = operation
    }

    func check<V: SIMD>(
        _ port: V,
        _ reference: V,
        _ inputs: @autoclosure () -> String
    ) where V.Scalar: ReferenceLane {
        let same = (0..<V.scalarCount).allSatisfy { port[$0].bits == reference[$0].bits }
        note(same, "port \(describe(port)), Highway \(describe(reference))", inputs)
    }

    func check<Storage>(
        _ port: SIMDMask<Storage>,
        _ reference: SIMDMask<Storage>,
        _ inputs: @autoclosure () -> String
    ) where Storage.Scalar: ReferenceLane {
        check(port._storage, reference._storage, inputs())
    }

    func check<V: ReferenceVector>(
        _ port: V,
        _ reference: V,
        _ inputs: @autoclosure () -> String
    ) {
        check(port.simd, reference.simd, inputs())
    }

    func check<M: ReferenceMask>(
        _ port: M,
        _ reference: M,
        _ inputs: @autoclosure () -> String
    ) {
        check(port.simd, reference.simd, inputs())
    }

    func check<Lane: ReferenceLane>(
        _ port: Lane,
        _ reference: Lane,
        _ inputs: @autoclosure () -> String
    ) {
        note(port.bits == reference.bits, "port \(hex(port)), Highway \(hex(reference))", inputs)
    }

    func check<Lane: ReferenceLane>(
        _ port: [Lane],
        _ reference: [Lane],
        _ inputs: @autoclosure () -> String
    ) {
        let same = port.map(\.bits) == reference.map(\.bits)
        note(same, "port \(describe(port)), Highway \(describe(reference))", inputs)
    }

    func check(_ port: Int, _ reference: Int, _ inputs: @autoclosure () -> String) {
        note(port == reference, "port \(port), Highway \(reference)", inputs)
    }

    func check(_ port: Bool, _ reference: Bool, _ inputs: @autoclosure () -> String) {
        note(port == reference, "port \(port), Highway \(reference)", inputs)
    }

    func record(sourceLocation: SourceLocation = #_sourceLocation) {
        guard count > 0 else { return }
        let details = examples.joined(separator: "\n")
        Issue.record(
            "\(operation): \(count) mismatches with Highway, for example:\n\(details)",
            sourceLocation: sourceLocation
        )
    }

    private func note(_ same: Bool, _ results: @autoclosure () -> String, _ inputs: () -> String) {
        guard !same else { return }
        count += 1
        if examples.count < 5 {
            examples.append("  \(inputs()): \(results())")
        }
    }
}
