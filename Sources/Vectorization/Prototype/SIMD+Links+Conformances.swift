extension UInt8: SIMDPrototypeLinkedLane, SIMDPrototypeIntegerLane, SIMDPrototypeUnsignedIntegerLane
{
    public typealias Unsigned = UInt8
    public typealias Signed = Int8
    public typealias HalfStorage = SIMDUInt8.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<UInt8>) -> SIMD<UInt8>.HalfVector {
        SIMD<UInt8>.HalfVector(storage: SIMDUInt8.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<UInt8>) -> SIMD<UInt8>.HalfVector {
        SIMD<UInt8>.HalfVector(storage: SIMDUInt8.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<UInt8>.HalfVector,
        _ b: SIMD<UInt8>.HalfVector
    ) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<UInt8>.Mask) -> SIMD<UInt8>.Mask {
        a
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt8>.Mask) -> SIMD<UInt8>.Mask {
        a
    }
}

extension UInt8: SIMDPrototypeWidenableLane {
    public typealias Wide = UInt16

    @export(implementation) @inline(always)
    public static func _widened(_ a: SIMD<UInt8>.HalfVector) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(widening: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(
        narrowing a: SIMD<UInt16>.Mask,
        _ b: SIMD<UInt16>.Mask
    ) -> SIMD<UInt8>.Mask {
        SIMD<UInt8>.Mask(storage: SIMDUInt8.mask(narrowing: a.storage, b.storage))
    }
}

extension Int8: SIMDPrototypeLinkedLane, SIMDPrototypeIntegerLane {
    public typealias Unsigned = UInt8
    public typealias Signed = Int8
    public typealias HalfStorage = SIMDInt8.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<Int8>) -> SIMD<Int8>.HalfVector {
        SIMD<Int8>.HalfVector(storage: SIMDInt8.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<Int8>) -> SIMD<Int8>.HalfVector {
        SIMD<Int8>.HalfVector(storage: SIMDInt8.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<Int8>.HalfVector,
        _ b: SIMD<Int8>.HalfVector
    ) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<Int8>.Mask) -> SIMD<UInt8>.Mask {
        SIMD<UInt8>.Mask(storage: SIMDUInt8.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt8>.Mask) -> SIMD<Int8>.Mask {
        SIMD<Int8>.Mask(storage: SIMDInt8.mask(rebinding: a.storage))
    }
}

extension Int8: SIMDPrototypeWidenableLane {
    public typealias Wide = Int16

    @export(implementation) @inline(always)
    public static func _widened(_ a: SIMD<Int8>.HalfVector) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(widening: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(
        narrowing a: SIMD<UInt16>.Mask,
        _ b: SIMD<UInt16>.Mask
    ) -> SIMD<Int8>.Mask {
        SIMD<Int8>.Mask(storage: SIMDInt8.mask(narrowing: a.storage, b.storage))
    }
}

extension UInt16: SIMDPrototypeLinkedLane, SIMDPrototypeIntegerLane,
    SIMDPrototypeUnsignedIntegerLane
{
    public typealias Unsigned = UInt16
    public typealias Signed = Int16
    public typealias HalfStorage = SIMDUInt16.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<UInt16>) -> SIMD<UInt16>.HalfVector {
        SIMD<UInt16>.HalfVector(storage: SIMDUInt16.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<UInt16>) -> SIMD<UInt16>.HalfVector {
        SIMD<UInt16>.HalfVector(storage: SIMDUInt16.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<UInt16>.HalfVector,
        _ b: SIMD<UInt16>.HalfVector
    ) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<UInt16>.Mask) -> SIMD<UInt16>.Mask {
        a
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt16>.Mask) -> SIMD<UInt16>.Mask {
        a
    }
}

extension UInt16: SIMDPrototypeWidenableLane {
    public typealias Wide = UInt32

    @export(implementation) @inline(always)
    public static func _widened(_ a: SIMD<UInt16>.HalfVector) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(widening: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(
        narrowing a: SIMD<UInt32>.Mask,
        _ b: SIMD<UInt32>.Mask
    ) -> SIMD<UInt16>.Mask {
        SIMD<UInt16>.Mask(storage: SIMDUInt16.mask(narrowing: a.storage, b.storage))
    }
}

extension UInt16: SIMDPrototypeWideIntegerLane {
    public typealias Narrow = UInt8

    @export(implementation) @inline(always)
    public static func _multiplyingEven(_ a: SIMD<UInt8>, _ b: SIMD<UInt8>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.multiplyingEven(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToSigned(_ a: SIMD<UInt16>) -> SIMD<Int8>.HalfVector {
        SIMD<Int8>.HalfVector(storage: SIMDInt8.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToUnsigned(_ a: SIMD<UInt16>) -> SIMD<UInt8>.HalfVector {
        SIMD<UInt8>.HalfVector(storage: SIMDUInt8.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _truncatedHalf(_ a: SIMD<UInt16>) -> SIMD<UInt8>.HalfVector {
        SIMD<UInt8>.HalfVector(storage: SIMDUInt8.halfVector(truncatingIfNeeded: a.storage))
    }
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@available(SwiftStdlib 5.3, *)
extension UInt16: SIMDPrototypeFloatConvertibleLane {
    public typealias Float = Float16

    @export(implementation) @inline(always)
    public static func _converted(toFloat a: SIMD<UInt16>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(converting: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _converted(fromFloat a: SIMD<Float16>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(converting: a.storage))
    }
}
#endif

extension Int16: SIMDPrototypeLinkedLane, SIMDPrototypeIntegerLane {
    public typealias Unsigned = UInt16
    public typealias Signed = Int16
    public typealias HalfStorage = SIMDInt16.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<Int16>) -> SIMD<Int16>.HalfVector {
        SIMD<Int16>.HalfVector(storage: SIMDInt16.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<Int16>) -> SIMD<Int16>.HalfVector {
        SIMD<Int16>.HalfVector(storage: SIMDInt16.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<Int16>.HalfVector,
        _ b: SIMD<Int16>.HalfVector
    ) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<Int16>.Mask) -> SIMD<UInt16>.Mask {
        SIMD<UInt16>.Mask(storage: SIMDUInt16.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt16>.Mask) -> SIMD<Int16>.Mask {
        SIMD<Int16>.Mask(storage: SIMDInt16.mask(rebinding: a.storage))
    }
}

extension Int16: SIMDPrototypeWidenableLane {
    public typealias Wide = Int32

    @export(implementation) @inline(always)
    public static func _widened(_ a: SIMD<Int16>.HalfVector) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(widening: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(
        narrowing a: SIMD<UInt32>.Mask,
        _ b: SIMD<UInt32>.Mask
    ) -> SIMD<Int16>.Mask {
        SIMD<Int16>.Mask(storage: SIMDInt16.mask(narrowing: a.storage, b.storage))
    }
}

extension Int16: SIMDPrototypeWideIntegerLane {
    public typealias Narrow = Int8

    @export(implementation) @inline(always)
    public static func _multiplyingEven(_ a: SIMD<Int8>, _ b: SIMD<Int8>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.multiplyingEven(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToSigned(_ a: SIMD<Int16>) -> SIMD<Int8>.HalfVector {
        SIMD<Int8>.HalfVector(storage: SIMDInt8.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToUnsigned(_ a: SIMD<Int16>) -> SIMD<UInt8>.HalfVector {
        SIMD<UInt8>.HalfVector(storage: SIMDUInt8.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _truncatedHalf(_ a: SIMD<UInt16>) -> SIMD<UInt8>.HalfVector {
        SIMD<UInt8>.HalfVector(storage: SIMDUInt8.halfVector(truncatingIfNeeded: a.storage))
    }
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@available(SwiftStdlib 5.3, *)
extension Int16: SIMDPrototypeFloatConvertibleLane {
    public typealias Float = Float16

    @export(implementation) @inline(always)
    public static func _converted(toFloat a: SIMD<Int16>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(converting: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _converted(fromFloat a: SIMD<Float16>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(converting: a.storage))
    }
}
#endif

extension UInt32: SIMDPrototypeLinkedLane, SIMDPrototypeIntegerLane,
    SIMDPrototypeUnsignedIntegerLane
{
    public typealias Unsigned = UInt32
    public typealias Signed = Int32
    public typealias HalfStorage = SIMDUInt32.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<UInt32>) -> SIMD<UInt32>.HalfVector {
        SIMD<UInt32>.HalfVector(storage: SIMDUInt32.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<UInt32>) -> SIMD<UInt32>.HalfVector {
        SIMD<UInt32>.HalfVector(storage: SIMDUInt32.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<UInt32>.HalfVector,
        _ b: SIMD<UInt32>.HalfVector
    ) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<UInt32>.Mask) -> SIMD<UInt32>.Mask {
        a
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt32>.Mask) -> SIMD<UInt32>.Mask {
        a
    }
}

extension UInt32: SIMDPrototypeWideIntegerLane {
    public typealias Narrow = UInt16

    @export(implementation) @inline(always)
    public static func _multiplyingEven(_ a: SIMD<UInt16>, _ b: SIMD<UInt16>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.multiplyingEven(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToSigned(_ a: SIMD<UInt32>) -> SIMD<Int16>.HalfVector {
        SIMD<Int16>.HalfVector(storage: SIMDInt16.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToUnsigned(_ a: SIMD<UInt32>) -> SIMD<UInt16>.HalfVector {
        SIMD<UInt16>.HalfVector(storage: SIMDUInt16.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _truncatedHalf(_ a: SIMD<UInt32>) -> SIMD<UInt16>.HalfVector {
        SIMD<UInt16>.HalfVector(storage: SIMDUInt16.halfVector(truncatingIfNeeded: a.storage))
    }
}

extension UInt32: SIMDPrototypeFloatConvertibleLane {
    public typealias Float = Swift.Float

    @export(implementation) @inline(always)
    public static func _converted(toFloat a: SIMD<UInt32>) -> SIMD<Swift.Float> {
        SIMD<Swift.Float>(storage: SIMDFloat.vector(converting: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _converted(fromFloat a: SIMD<Swift.Float>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(converting: a.storage))
    }
}

extension UInt32: SIMDPrototypeGatherableLane {
    @export(implementation) @inline(always)
    public static func _gather(from: UnsafePointer<UInt32>, indices: SIMD<Int32>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: unsafe SIMDUInt32.gather(from: from, indices: indices.storage))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func _gather(from span: Span<UInt32>, indices: SIMD<Int32>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.gather(from: span, indices: indices.storage))
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func _gather(
        fromUnchecked span: Span<UInt32>,
        indices: SIMD<Int32>
    ) -> SIMD<UInt32> {
        SIMD<UInt32>(
            storage: unsafe SIMDUInt32.gather(fromUnchecked: span, indices: indices.storage)
        )
    }
}

extension Int32: SIMDPrototypeLinkedLane, SIMDPrototypeIntegerLane {
    public typealias Unsigned = UInt32
    public typealias Signed = Int32
    public typealias HalfStorage = SIMDInt32.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<Int32>) -> SIMD<Int32>.HalfVector {
        SIMD<Int32>.HalfVector(storage: SIMDInt32.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<Int32>) -> SIMD<Int32>.HalfVector {
        SIMD<Int32>.HalfVector(storage: SIMDInt32.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<Int32>.HalfVector,
        _ b: SIMD<Int32>.HalfVector
    ) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<Int32>.Mask) -> SIMD<UInt32>.Mask {
        SIMD<UInt32>.Mask(storage: SIMDUInt32.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt32>.Mask) -> SIMD<Int32>.Mask {
        SIMD<Int32>.Mask(storage: SIMDInt32.mask(rebinding: a.storage))
    }
}

extension Int32: SIMDPrototypeWideIntegerLane {
    public typealias Narrow = Int16

    @export(implementation) @inline(always)
    public static func _multiplyingEven(_ a: SIMD<Int16>, _ b: SIMD<Int16>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.multiplyingEven(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToSigned(_ a: SIMD<Int32>) -> SIMD<Int16>.HalfVector {
        SIMD<Int16>.HalfVector(storage: SIMDInt16.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _clampedHalfToUnsigned(_ a: SIMD<Int32>) -> SIMD<UInt16>.HalfVector {
        SIMD<UInt16>.HalfVector(storage: SIMDUInt16.halfVector(clamping: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _truncatedHalf(_ a: SIMD<UInt32>) -> SIMD<UInt16>.HalfVector {
        SIMD<UInt16>.HalfVector(storage: SIMDUInt16.halfVector(truncatingIfNeeded: a.storage))
    }
}

extension Int32: SIMDPrototypeFloatConvertibleLane {
    public typealias Float = Swift.Float

    @export(implementation) @inline(always)
    public static func _converted(toFloat a: SIMD<Int32>) -> SIMD<Swift.Float> {
        SIMD<Swift.Float>(storage: SIMDFloat.vector(converting: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _converted(fromFloat a: SIMD<Swift.Float>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(converting: a.storage))
    }
}

extension Int32: SIMDPrototypeGatherableLane {
    @export(implementation) @inline(always)
    public static func _gather(from: UnsafePointer<Int32>, indices: SIMD<Int32>) -> SIMD<Int32> {
        SIMD<Int32>(storage: unsafe SIMDInt32.gather(from: from, indices: indices.storage))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func _gather(from span: Span<Int32>, indices: SIMD<Int32>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.gather(from: span, indices: indices.storage))
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func _gather(
        fromUnchecked span: Span<Int32>,
        indices: SIMD<Int32>
    ) -> SIMD<Int32> {
        SIMD<Int32>(storage: unsafe SIMDInt32.gather(fromUnchecked: span, indices: indices.storage))
    }
}

extension Float: SIMDPrototypeLinkedLane, SIMDPrototypeFloatLane {
    public typealias Unsigned = UInt32
    public typealias Signed = Int32
    public typealias HalfStorage = SIMDFloat.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<Float>) -> SIMD<Float>.HalfVector {
        SIMD<Float>.HalfVector(storage: SIMDFloat.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<Float>) -> SIMD<Float>.HalfVector {
        SIMD<Float>.HalfVector(storage: SIMDFloat.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<Float>.HalfVector,
        _ b: SIMD<Float>.HalfVector
    ) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<Float>.Mask) -> SIMD<UInt32>.Mask {
        SIMD<UInt32>.Mask(storage: SIMDUInt32.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt32>.Mask) -> SIMD<Float>.Mask {
        SIMD<Float>.Mask(storage: SIMDFloat.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _roundedToNearestOrEven(_ a: SIMD<Float>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(roundingToNearestOrEven: a.storage))
    }
}

extension Float: SIMDPrototypeGatherableLane {
    @export(implementation) @inline(always)
    public static func _gather(from: UnsafePointer<Float>, indices: SIMD<Int32>) -> SIMD<Float> {
        SIMD<Float>(storage: unsafe SIMDFloat.gather(from: from, indices: indices.storage))
    }

    @available(SwiftStdlib 5.1, *)
    @export(implementation) @inline(always)
    public static func _gather(from span: Span<Float>, indices: SIMD<Int32>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.gather(from: span, indices: indices.storage))
    }

    @available(SwiftStdlib 5.1, *)
    @unsafe @export(implementation) @inline(always)
    public static func _gather(
        fromUnchecked span: Span<Float>,
        indices: SIMD<Int32>
    ) -> SIMD<Float> {
        SIMD<Float>(storage: unsafe SIMDFloat.gather(fromUnchecked: span, indices: indices.storage))
    }
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@available(SwiftStdlib 5.3, *)
extension Float16: SIMDPrototypeLinkedLane, SIMDPrototypeFloatLane {
    public typealias Unsigned = UInt16
    public typealias Signed = Int16
    public typealias HalfStorage = SIMDFloat16.HalfVector

    @export(implementation) @inline(always)
    public static func _lowerHalf(_ a: SIMD<Float16>) -> SIMD<Float16>.HalfVector {
        SIMD<Float16>.HalfVector(storage: SIMDFloat16.lowerHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _upperHalf(_ a: SIMD<Float16>) -> SIMD<Float16>.HalfVector {
        SIMD<Float16>.HalfVector(storage: SIMDFloat16.upperHalf(a.storage))
    }

    @export(implementation) @inline(always)
    public static func _combining(
        _ a: SIMD<Float16>.HalfVector,
        _ b: SIMD<Float16>.HalfVector
    ) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.combining(a.storage, b.storage))
    }

    @export(implementation) @inline(always)
    public static func _maskToUnsigned(_ a: SIMD<Float16>.Mask) -> SIMD<UInt16>.Mask {
        SIMD<UInt16>.Mask(storage: SIMDUInt16.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _mask(fromUnsigned a: SIMD<UInt16>.Mask) -> SIMD<Float16>.Mask {
        SIMD<Float16>.Mask(storage: SIMDFloat16.mask(rebinding: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _roundedToNearestOrEven(_ a: SIMD<Float16>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(roundingToNearestOrEven: a.storage))
    }
}
#endif
