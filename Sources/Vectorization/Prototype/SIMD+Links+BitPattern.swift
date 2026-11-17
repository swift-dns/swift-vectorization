extension UInt8 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<UInt8> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Swift.Float>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<UInt8> {
        SIMD<UInt8>(storage: SIMDUInt8.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<UInt8>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfUInt8: a)
    }
}

extension Int8 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<Int8> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Swift.Float>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<Int8> {
        SIMD<Int8>(storage: SIMDInt8.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Int8>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfInt8: a)
    }
}

extension UInt16 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<UInt16> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Swift.Float>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<UInt16> {
        SIMD<UInt16>(storage: SIMDUInt16.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<UInt16>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfUInt16: a)
    }
}

extension Int16 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<Int16> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Swift.Float>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<Int16> {
        SIMD<Int16>(storage: SIMDInt16.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Int16>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfInt16: a)
    }
}

extension UInt32 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<UInt32> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Swift.Float>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<UInt32> {
        SIMD<UInt32>(storage: SIMDUInt32.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<UInt32>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfUInt32: a)
    }
}

extension Int32 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<Int32> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Swift.Float>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<Int32> {
        SIMD<Int32>(storage: SIMDInt32.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Int32>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfInt32: a)
    }
}

extension Float {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Float>) -> SIMD<Float> {
        a
    }

    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    @available(SwiftStdlib 5.3, *)
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<Float> {
        SIMD<Float>(storage: SIMDFloat.vector(bitPattern: a.storage))
    }
    #endif

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Float>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfFloat: a)
    }
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@available(SwiftStdlib 5.3, *)
extension Float16 {
    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt8 a: SIMD<UInt8>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt8 a: SIMD<Int8>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt16 a: SIMD<UInt16>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt16 a: SIMD<Int16>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfUInt32 a: SIMD<UInt32>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfInt32 a: SIMD<Int32>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat a: SIMD<Float>) -> SIMD<Float16> {
        SIMD<Float16>(storage: SIMDFloat16.vector(bitPattern: a.storage))
    }

    @export(implementation) @inline(always)
    public static func _vector(bitPatternOfFloat16 a: SIMD<Float16>) -> SIMD<Float16> {
        a
    }

    @export(implementation) @inline(always)
    public static func _vector<Result: SIMDPrototypeLinkedLane>(
        bitPattern a: SIMD<Float16>,
        as result: Result.Type
    ) -> SIMD<Result> {
        Result._vector(bitPatternOfFloat16: a)
    }
}
#endif
