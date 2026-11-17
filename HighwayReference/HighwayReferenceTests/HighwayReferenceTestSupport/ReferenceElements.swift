package import Vectorization

package protocol ReferenceElement: ReferenceLane, SIMDElement
where
    _SIMDVector: Swift.SIMD,
    _SIMDVector.Scalar: ReferenceLane,
    _SIMDMask == SIMDMask<MaskStorage>,
    _RawHalfMask: BitwiseCopyable
{
    associatedtype MaskStorage: Swift.SIMD
    where MaskStorage.Scalar: ReferenceLane & FixedWidthInteger & SignedInteger

    static func simdLane(_ lane: Self) -> _SIMDVector.Scalar

    static func vector(_ simd: _SIMDVector) -> SIMD<Self>
    static func simd(of vector: SIMD<Self>) -> _SIMDVector

    static func mask(_ simd: SIMDMask<MaskStorage>) -> SIMD<Self>.Mask
    static func simd(of mask: SIMD<Self>.Mask) -> SIMDMask<MaskStorage>

    static func halfVector(lanes: [Self]) -> SIMD<Self>.HalfVector
    static func lanes(of vector: SIMD<Self>.HalfVector) -> [Self]

    static func blockVector(lanes: [Self]) -> SIMD<Self>.BlockVector
    static func lanes(of vector: SIMD<Self>.BlockVector) -> [Self]
}

extension ReferenceElement where _SIMDVector.Scalar == Self {
    package static func simdLane(_ lane: Self) -> _SIMDVector.Scalar { lane }
}

package protocol ReferenceQuarterElement: ReferenceElement, SIMDQuarterVectorElement
where _RawQuarterMask: BitwiseCopyable {
    static func quarterVector(lanes: [Self]) -> SIMD<Self>.QuarterVector
    static func lanes(of vector: SIMD<Self>.QuarterVector) -> [Self]
}

package protocol ReferenceEighthElement: ReferenceQuarterElement, SIMDEighthVectorElement
where _RawEighthMask: BitwiseCopyable {
    static func eighthVector(lanes: [Self]) -> SIMD<Self>.EighthVector
    static func lanes(of vector: SIMD<Self>.EighthVector) -> [Self]
}

extension SIMD: ReferenceVector where Lane: ReferenceElement {
    package typealias Simd = Lane._SIMDVector
    package typealias InputLane = Lane

    package init(referenceSimd simd: Lane._SIMDVector) {
        self = Lane.vector(simd)
    }

    package var referenceSimd: Lane._SIMDVector {
        Lane.simd(of: self)
    }

    package static func simdLane(_ lane: Lane) -> Lane._SIMDVector.Scalar {
        Lane.simdLane(lane)
    }
}

extension SIMD.Mask: ReferenceMask where Lane: ReferenceElement {
    package typealias Storage = Lane.MaskStorage

    package init(referenceSimd simd: SIMDMask<Lane.MaskStorage>) {
        self = Lane.mask(simd)
    }

    package var referenceSimd: SIMDMask<Lane.MaskStorage> {
        Lane.simd(of: self)
    }
}

extension SIMD.HalfVector: ReferenceNarrowVector where Lane: ReferenceElement {
    package typealias Raw = Lane._RawHalfVector

    package static var laneCount: Int { SIMD<Lane>.laneCount / 2 }

    package init(lanes: [Lane]) {
        self = Lane.halfVector(lanes: lanes)
    }

    package var lanes: [Lane] {
        Lane.lanes(of: self)
    }
}

extension SIMD.HalfMask: ReferenceNarrowMask where Lane: ReferenceElement {
    package typealias MaskLane = Lane.MaskStorage.Scalar
    package typealias Raw = Lane._RawHalfMask

    package static var laneCount: Int { SIMD<Lane>.laneCount / 2 }
}

extension SIMD.BlockVector: ReferenceNarrowVector where Lane: ReferenceElement {
    package typealias Raw = Lane._RawBlockVector

    package static var laneCount: Int { 16 / MemoryLayout<Lane>.stride }

    package init(lanes: [Lane]) {
        self = Lane.blockVector(lanes: lanes)
    }

    package var lanes: [Lane] {
        Lane.lanes(of: self)
    }
}

extension SIMD.QuarterVector: ReferenceNarrowVector where Lane: ReferenceQuarterElement {
    package typealias Raw = Lane._RawQuarterVector

    package static var laneCount: Int { SIMD<Lane>.laneCount / 4 }

    package init(lanes: [Lane]) {
        self = Lane.quarterVector(lanes: lanes)
    }

    package var lanes: [Lane] {
        Lane.lanes(of: self)
    }
}

extension SIMD.QuarterMask: ReferenceNarrowMask where Lane: ReferenceQuarterElement {
    package typealias MaskLane = Lane.MaskStorage.Scalar
    package typealias Raw = Lane._RawQuarterMask

    package static var laneCount: Int { SIMD<Lane>.laneCount / 4 }
}

extension SIMD.EighthVector: ReferenceNarrowVector where Lane: ReferenceEighthElement {
    package typealias Raw = Lane._RawEighthVector

    package static var laneCount: Int { SIMD<Lane>.laneCount / 8 }

    package init(lanes: [Lane]) {
        self = Lane.eighthVector(lanes: lanes)
    }

    package var lanes: [Lane] {
        Lane.lanes(of: self)
    }
}

extension SIMD.EighthMask: ReferenceNarrowMask where Lane: ReferenceEighthElement {
    package typealias MaskLane = Lane.MaskStorage.Scalar
    package typealias Raw = Lane._RawEighthMask

    package static var laneCount: Int { SIMD<Lane>.laneCount / 8 }
}
