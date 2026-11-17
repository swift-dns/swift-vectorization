extension SIMDDirect {
    @export(implementation) @inline(always)
    public static var laneCount: Int { Lane._laneCount }

    @export(implementation) @inline(always)
    public static func zero() -> SIMDDirect {
        Lane._zero()
    }

    @export(implementation) @inline(always)
    public static func repeating(_ value: Lane) -> SIMDDirect {
        Lane._repeating(value)
    }

    @export(implementation) @inline(always)
    public static func load(from: UnsafePointer<Lane>) -> SIMDDirect {
        unsafe Lane._load(from: from)
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func load(from span: Span<Lane>) -> SIMDDirect {
        Lane._load(from: span)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func load(fromUnchecked span: Span<Lane>) -> SIMDDirect {
        unsafe Lane._load(fromUnchecked: span)
    }

    @export(implementation) @inline(always)
    public static func store(_ a: SIMDDirect, to: UnsafeMutablePointer<Lane>) {
        unsafe Lane._store(a, to: to)
    }

    @export(implementation) @inline(always)
    public static func adding(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        Lane._adding(a, b)
    }

    @export(implementation) @inline(always)
    public static func multiplyAdding(
        _ a: SIMDDirect,
        _ b: SIMDDirect,
        _ c: SIMDDirect
    ) -> SIMDDirect {
        Lane._multiplyAdding(a, b, c)
    }

    @export(implementation) @inline(always)
    public static func bitwiseXor(_ a: SIMDDirect, _ b: SIMDDirect) -> SIMDDirect {
        Lane._bitwiseXor(a, b)
    }

    @export(implementation) @inline(always)
    public static func equalTo(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Lane._equalTo(a, b)
    }

    @export(implementation) @inline(always)
    public static func lessThan(_ a: SIMDDirect, _ b: SIMDDirect) -> Mask {
        Lane._lessThan(a, b)
    }

    @export(implementation) @inline(always)
    public static func selectingOrZero(_ mask: Mask, _ a: SIMDDirect) -> SIMDDirect {
        Lane._selectingOrZero(mask, a)
    }

    @export(implementation) @inline(always)
    public static func firstLanes(count: Int) -> Mask {
        Lane._firstLanes(count: count)
    }

    @export(implementation) @inline(always)
    public static func trueCount(_ mask: Mask) -> Int {
        Lane._trueCount(mask)
    }

    @export(implementation) @inline(always)
    public static func sum(_ a: SIMDDirect) -> Lane {
        Lane._sum(a)
    }

    @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, by lanes: Int) -> SIMDDirect {
        Lane._slideUpLanes(a, by: lanes)
    }

    @unsafe @export(implementation) @inline(always)
    public static func slideUpLanes(_ a: SIMDDirect, byUnchecked lanes: Int) -> SIMDDirect {
        unsafe Lane._slideUpLanes(a, byUnchecked: lanes)
    }
}

extension SIMDDirect where Lane: SIMDDirectIntegerLane {
    @export(implementation) @inline(always)
    public static func shiftedLeft(_ a: SIMDDirect, by bits: Int) -> SIMDDirect {
        Lane._shiftedLeft(a, by: bits)
    }
}
