public protocol SIMDPrototypeLane {
    associatedtype Ops: SIMDElement where Ops.Lane == Self
}

public struct SIMD<Lane: SIMDPrototypeLane> {
    public var storage: Lane.Ops.Vector

    @export(implementation) @inline(always)
    public init(storage: Lane.Ops.Vector) {
        self.storage = storage
    }

    public struct Mask {
        public var storage: Lane.Ops.Mask

        @export(implementation) @inline(always)
        public init(storage: Lane.Ops.Mask) {
            self.storage = storage
        }
    }

    @export(implementation) @inline(always)
    public static var laneCount: Int { Lane.Ops.laneCount }

    @export(implementation) @inline(always)
    public static var blockCount: Int { Lane.Ops.blockCount }

    @export(implementation) @inline(always)
    public static var canLookup8: Bool { Lane.Ops.canLookup8 }

    @export(implementation) @inline(always)
    public static var canLookup16: Bool { Lane.Ops.canLookup16 }

    @export(implementation) @inline(always)
    public static var canReverse4: Bool { Lane.Ops.canReverse4 }

    @export(implementation) @inline(always)
    public static var canReverse8: Bool { Lane.Ops.canReverse8 }
}

extension SIMD: Sendable where Lane.Ops.Vector: Sendable {}

extension SIMD.Mask: Sendable where Lane.Ops.Mask: Sendable {}

extension UInt8: SIMDPrototypeLane {
    public typealias Ops = SIMDUInt8
}

extension UInt16: SIMDPrototypeLane {
    public typealias Ops = SIMDUInt16
}

extension UInt32: SIMDPrototypeLane {
    public typealias Ops = SIMDUInt32
}

extension UInt64: SIMDPrototypeLane {
    public typealias Ops = SIMDUInt64
}

extension Int8: SIMDPrototypeLane {
    public typealias Ops = SIMDInt8
}

extension Int16: SIMDPrototypeLane {
    public typealias Ops = SIMDInt16
}

extension Int32: SIMDPrototypeLane {
    public typealias Ops = SIMDInt32
}

extension Int64: SIMDPrototypeLane {
    public typealias Ops = SIMDInt64
}

extension Float: SIMDPrototypeLane {
    public typealias Ops = SIMDFloat
}

extension Double: SIMDPrototypeLane {
    public typealias Ops = SIMDDouble
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@available(SwiftStdlib 5.3, *)
extension Float16: SIMDPrototypeLane {
    public typealias Ops = SIMDFloat16
}
#endif
