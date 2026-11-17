public protocol SIMDPrototypeLinkedLane: SIMDPrototypeLane {
    associatedtype Unsigned: SIMDPrototypeLinkedLane
    where Unsigned.Unsigned == Unsigned, Unsigned.Signed == Signed
    associatedtype Signed: SIMDPrototypeLinkedLane
    where Signed.Signed == Signed, Signed.Unsigned == Unsigned
    associatedtype HalfStorage

    static func _lowerHalf(_ a: SIMD<Self>) -> SIMD<Self>.HalfVector
    static func _upperHalf(_ a: SIMD<Self>) -> SIMD<Self>.HalfVector
    static func _combining(_ a: SIMD<Self>.HalfVector, _ b: SIMD<Self>.HalfVector) -> SIMD<Self>

    static func _maskToUnsigned(_ a: SIMD<Self>.Mask) -> SIMD<Unsigned>.Mask
    static func _mask(fromUnsigned a: SIMD<Unsigned>.Mask) -> SIMD<Self>.Mask

    static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Self>,
        as result: Result.Type
    ) -> SIMD<Result>
    static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<Self>
    static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<Self>
    static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<Self>
    static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<Self>
    static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<Self>
    static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<Self>
    static func _vector(bitPatternOfFloat a: SIMD<Float>) -> SIMD<Self>
    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<Self>
    #endif
}

public protocol SIMDPrototypeIntegerLane: SIMDPrototypeLinkedLane
where Unsigned: SIMDPrototypeIntegerLane, Signed: SIMDPrototypeIntegerLane {}

public protocol SIMDPrototypeUnsignedIntegerLane: SIMDPrototypeIntegerLane
where Unsigned == Self {}

public protocol SIMDPrototypeFloatLane: SIMDPrototypeLinkedLane
where
    Signed: SIMDPrototypeFloatConvertibleLane,
    Unsigned: SIMDPrototypeFloatConvertibleLane,
    Signed.Float == Self,
    Unsigned.Float == Self
{
    static func _roundedToNearestOrEven(_ a: SIMD<Self>) -> SIMD<Signed>
}

public protocol SIMDPrototypeWidenableLane: SIMDPrototypeLinkedLane {
    associatedtype Wide: SIMDPrototypeNarrowableLane where Wide.Narrow == Self

    static func _widened(_ a: SIMD<Self>.HalfVector) -> SIMD<Wide>
    static func _mask(
        narrowing a: SIMD<Wide.Unsigned>.Mask,
        _ b: SIMD<Wide.Unsigned>.Mask
    ) -> SIMD<Self>.Mask
}

public protocol SIMDPrototypeNarrowableLane: SIMDPrototypeLinkedLane {
    associatedtype Narrow: SIMDPrototypeWidenableLane where Narrow.Wide == Self
}

public protocol SIMDPrototypeWideIntegerLane: SIMDPrototypeIntegerLane, SIMDPrototypeNarrowableLane
where Narrow: SIMDPrototypeIntegerLane, Unsigned: SIMDPrototypeWideIntegerLane {
    static func _multiplyingEven(_ a: SIMD<Narrow>, _ b: SIMD<Narrow>) -> SIMD<Self>
    static func _clampedHalfToSigned(_ a: SIMD<Self>) -> SIMD<Narrow.Signed>.HalfVector
    static func _clampedHalfToUnsigned(_ a: SIMD<Self>) -> SIMD<Narrow.Unsigned>.HalfVector
    static func _truncatedHalf(_ a: SIMD<Unsigned>) -> SIMD<Unsigned.Narrow>.HalfVector
}

public protocol SIMDPrototypeFloatConvertibleLane: SIMDPrototypeIntegerLane {
    associatedtype Float: SIMDPrototypeFloatLane where Float.Unsigned == Unsigned

    static func _converted(toFloat a: SIMD<Self>) -> SIMD<Float>
    static func _converted(fromFloat a: SIMD<Float>) -> SIMD<Self>
}

public protocol SIMDPrototypeGatherableLane: SIMDPrototypeLinkedLane {
    static func _gather(from: UnsafePointer<Self>, indices: SIMD<Signed>) -> SIMD<Self>

    @available(SwiftStdlib 5.1, *)
    static func _gather(from span: Span<Self>, indices: SIMD<Signed>) -> SIMD<Self>

    @available(SwiftStdlib 5.1, *)
    @unsafe static func _gather(fromUnchecked span: Span<Self>, indices: SIMD<Signed>) -> SIMD<Self>
}

extension SIMD where Lane: SIMDPrototypeLinkedLane {
    public struct HalfVector {
        public var storage: Lane.HalfStorage

        @export(implementation) @inline(always)
        public init(storage: Lane.HalfStorage) {
            self.storage = storage
        }
    }
}

extension SIMD.HalfVector: Sendable
where Lane: SIMDPrototypeLinkedLane, Lane.HalfStorage: Sendable {}

extension SIMD where Lane: SIMDPrototypeLinkedLane {
    @export(implementation) @inline(always)
    public static func lowerHalf(_ a: SIMD) -> HalfVector {
        Lane._lowerHalf(a)
    }

    @export(implementation) @inline(always)
    public static func upperHalf(_ a: SIMD) -> HalfVector {
        Lane._upperHalf(a)
    }

    @export(implementation) @inline(always)
    public static func combining(_ a: HalfVector, _ b: HalfVector) -> SIMD {
        Lane._combining(a, b)
    }

    @export(implementation) @inline(always)
    public static func vector<Source: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Source>
    ) -> SIMD {
        Source._vector(bitPattern: a, as: Lane.self)
    }

    @export(implementation) @inline(always)
    public static func mask<Source: SIMDPrototypeLinkedLane>(
        rebinding a: SIMD<Source>.Mask
    ) -> Mask where Source.Unsigned == Lane.Unsigned {
        Lane._mask(fromUnsigned: Source._maskToUnsigned(a))
    }
}

extension SIMD {
    @export(implementation) @inline(always)
    public static func vector<Source: SIMDPrototypeWidenableLane>(
        widening a: SIMD<Source>.HalfVector
    ) -> SIMD where Source.Wide == Lane {
        Source._widened(a)
    }
}

extension SIMD where Lane: SIMDPrototypeWideIntegerLane {
    @export(implementation) @inline(always)
    public static func multiplyingEven(_ a: SIMD<Lane.Narrow>, _ b: SIMD<Lane.Narrow>) -> SIMD {
        Lane._multiplyingEven(a, b)
    }
}

extension SIMD where Lane: SIMDPrototypeIntegerLane {
    @export(implementation) @inline(always)
    public static func halfVector<Source: SIMDPrototypeWideIntegerLane>(
        clamping a: SIMD<Source>
    ) -> HalfVector where Source.Narrow.Signed == Lane {
        Source._clampedHalfToSigned(a)
    }

    @export(implementation) @inline(always)
    public static func halfVector<Source: SIMDPrototypeWideIntegerLane>(
        clamping a: SIMD<Source>
    ) -> HalfVector where Source.Narrow.Unsigned == Lane {
        Source._clampedHalfToUnsigned(a)
    }

    @export(implementation) @inline(always)
    public static func vector<Source: SIMDPrototypeFloatLane>(
        roundingToNearestOrEven a: SIMD<Source>
    ) -> SIMD where Source.Signed == Lane {
        Source._roundedToNearestOrEven(a)
    }
}

extension SIMD where Lane: SIMDPrototypeFloatLane {
    @export(implementation) @inline(always)
    public static func vector<Source: SIMDPrototypeFloatConvertibleLane>(
        converting a: SIMD<Source>
    ) -> SIMD where Source.Float == Lane {
        Source._converted(toFloat: a)
    }
}

extension SIMD where Lane: SIMDPrototypeFloatConvertibleLane {
    @export(implementation) @inline(always)
    public static func vector(converting a: SIMD<Lane.Float>) -> SIMD {
        Lane._converted(fromFloat: a)
    }
}

extension SIMD where Lane: SIMDPrototypeUnsignedIntegerLane {
    @export(implementation) @inline(always)
    public static func halfVector<
        Source: SIMDPrototypeUnsignedIntegerLane & SIMDPrototypeWideIntegerLane
    >(
        truncatingIfNeeded a: SIMD<Source>
    ) -> HalfVector where Source.Narrow == Lane {
        Source._truncatedHalf(a)
    }
}

extension SIMD where Lane: SIMDPrototypeWidenableLane {
    @export(implementation) @inline(always)
    public static func mask<Source: SIMDPrototypeLinkedLane>(
        narrowing a: SIMD<Source>.Mask,
        _ b: SIMD<Source>.Mask
    ) -> Mask where Source.Unsigned == Lane.Wide.Unsigned {
        Lane._mask(narrowing: Source._maskToUnsigned(a), Source._maskToUnsigned(b))
    }
}

extension SIMD where Lane: SIMDPrototypeGatherableLane {
    @export(implementation) @inline(always)
    public static func gather(from: UnsafePointer<Lane>, indices: SIMD<Lane.Signed>) -> SIMD {
        unsafe Lane._gather(from: from, indices: indices)
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func gather(from span: Span<Lane>, indices: SIMD<Lane.Signed>) -> SIMD {
        Lane._gather(from: span, indices: indices)
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func gather(fromUnchecked span: Span<Lane>, indices: SIMD<Lane.Signed>) -> SIMD {
        unsafe Lane._gather(fromUnchecked: span, indices: indices)
    }
}
