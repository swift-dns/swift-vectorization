public protocol SIMDDirectLane {
    associatedtype RawVector
    associatedtype RawMask

    static var _laneCount: Int { get }

    static func _zero() -> SIMDDirect<Self>
    static func _repeating(_ value: Self) -> SIMDDirect<Self>
    static func _load(from: UnsafePointer<Self>) -> SIMDDirect<Self>
    @available(SwiftStdlib 5.1, *)
    static func _load(from span: Span<Self>) -> SIMDDirect<Self>
    @available(SwiftStdlib 5.1, *)
    @unsafe static func _load(fromUnchecked span: Span<Self>) -> SIMDDirect<Self>
    static func _store(_ a: SIMDDirect<Self>, to: UnsafeMutablePointer<Self>)
    static func _adding(_ a: SIMDDirect<Self>, _ b: SIMDDirect<Self>) -> SIMDDirect<Self>
    static func _multiplyAdding(
        _ a: SIMDDirect<Self>,
        _ b: SIMDDirect<Self>,
        _ c: SIMDDirect<Self>
    ) -> SIMDDirect<Self>
    static func _bitwiseXor(_ a: SIMDDirect<Self>, _ b: SIMDDirect<Self>) -> SIMDDirect<Self>
    static func _equalTo(_ a: SIMDDirect<Self>, _ b: SIMDDirect<Self>) -> SIMDDirect<Self>.Mask
    static func _lessThan(_ a: SIMDDirect<Self>, _ b: SIMDDirect<Self>) -> SIMDDirect<Self>.Mask
    static func _selectingOrZero(
        _ mask: SIMDDirect<Self>.Mask,
        _ a: SIMDDirect<Self>
    ) -> SIMDDirect<Self>
    static func _firstLanes(count: Int) -> SIMDDirect<Self>.Mask
    static func _trueCount(_ mask: SIMDDirect<Self>.Mask) -> Int
    static func _sum(_ a: SIMDDirect<Self>) -> Self
    static func _slideUpLanes(_ a: SIMDDirect<Self>, by lanes: Int) -> SIMDDirect<Self>
    @unsafe static func _slideUpLanes(
        _ a: SIMDDirect<Self>,
        byUnchecked lanes: Int
    ) -> SIMDDirect<Self>
}

public protocol SIMDDirectIntegerLane: SIMDDirectLane {
    static func _shiftedLeft(_ a: SIMDDirect<Self>, by bits: Int) -> SIMDDirect<Self>
}

public struct SIMDDirect<Lane: SIMDDirectLane> {
    public var raw: Lane.RawVector

    @export(implementation) @inline(always)
    public init(raw: Lane.RawVector) {
        self.raw = raw
    }

    public struct Mask {
        public var raw: Lane.RawMask

        @export(implementation) @inline(always)
        public init(raw: Lane.RawMask) {
            self.raw = raw
        }
    }
}

extension SIMDDirect: Sendable where Lane.RawVector: Sendable {}

extension SIMDDirect.Mask: Sendable where Lane.RawMask: Sendable {}
