// Generates the C header of the ops, the Swift layer over it, the C++ header of the Highway ops
// they are tested against, the tests that compare the two, and the functions that put both of
// them into machine code to be compared, from the op list below.
//
// Run from the repository root:
//
//     swift utils/GenerateVectorizationOps.swift

import Foundation

enum Category: Hashable {
    case unsignedInteger
    case signedInteger
    case float
}

struct Element {
    let suffix: String
    let cType: String
    let swiftType: String
    let category: Category
    let bits: Int
    var width = 16

    var tag: String { "Tag\(suffix)" }
    var vector: String { "Vector\(suffix)" }
    var mask: String { "Mask\(suffix)" }
    var outVector: String { "OutVector\(suffix)" }
    var namespace: String { "SIMD\(swiftType)" }
    var laneCount: Int { width / (bits / 8) }
    var blockLaneCount: Int { 16 / (bits / 8) }
    var cSuffix: String { suffix.lowercased() }
    var cVector: String { "cvectorization_ops_vector_\(cSuffix)" }
    var cBlock: String { "cvectorization_ops_block_\(cSuffix)" }
    var cMask: String { "cvectorization_ops_mask_\(cSuffix)" }
    var cRawVector: String { "cvectorization_ops_raw_vector_\(cSuffix)" }
    var cRawMask: String { "cvectorization_ops_raw_mask_\(cSuffix)" }
    var cToRawVector: String { "cvectorization_ops_to_raw_vector_\(cSuffix)" }
    var cFromRawVector: String { "cvectorization_ops_from_raw_vector_\(cSuffix)" }
    var cToRawMask: String { "cvectorization_ops_to_raw_mask_\(cSuffix)" }
    var cFromRawMask: String { "cvectorization_ops_from_raw_mask_\(cSuffix)" }
    var hasOpaqueVector: Bool { category != .float }
    var cUnsignedLane: String { "uint\(bits)_t" }
    var cUnsignedVector: String { "cvectorization_ops_vector_u\(bits)" }
    var cMaskLane: String { "int\(bits)_t" }
    var swiftMaskLane: String { "Int\(bits)" }

    func at(width: Int) -> Element {
        var scaled = self
        scaled.width = width
        return scaled
    }
}

let elements: [Element] = [
    Element(
        suffix: "U8",
        cType: "uint8_t",
        swiftType: "UInt8",
        category: .unsignedInteger,
        bits: 8
    ),
    Element(
        suffix: "U16",
        cType: "uint16_t",
        swiftType: "UInt16",
        category: .unsignedInteger,
        bits: 16
    ),
    Element(
        suffix: "U32",
        cType: "uint32_t",
        swiftType: "UInt32",
        category: .unsignedInteger,
        bits: 32
    ),
    Element(
        suffix: "U64",
        cType: "uint64_t",
        swiftType: "UInt64",
        category: .unsignedInteger,
        bits: 64
    ),
    Element(suffix: "I8", cType: "int8_t", swiftType: "Int8", category: .signedInteger, bits: 8),
    Element(
        suffix: "I16",
        cType: "int16_t",
        swiftType: "Int16",
        category: .signedInteger,
        bits: 16
    ),
    Element(
        suffix: "I32",
        cType: "int32_t",
        swiftType: "Int32",
        category: .signedInteger,
        bits: 32
    ),
    Element(
        suffix: "I64",
        cType: "int64_t",
        swiftType: "Int64",
        category: .signedInteger,
        bits: 64
    ),
    Element(suffix: "F32", cType: "float", swiftType: "Float", category: .float, bits: 32),
    Element(suffix: "F64", cType: "double", swiftType: "Double", category: .float, bits: 64),
]

struct Applies {
    var categories: Set<Category>
    var bits: Set<Int>?

    func matches(_ element: Element) -> Bool {
        guard categories.contains(element.category) else { return false }
        guard let bits else { return true }
        return bits.contains(element.bits)
    }

    static let all = Applies(categories: [.unsignedInteger, .signedInteger, .float], bits: nil)
    static let integer = Applies(categories: [.unsignedInteger, .signedInteger], bits: nil)
    static let unsigned = Applies(categories: [.unsignedInteger], bits: nil)
    static let float = Applies(categories: [.float], bits: nil)
    static let signedOrFloat = Applies(categories: [.signedInteger, .float], bits: nil)

    static func integer(bits: Set<Int>) -> Applies {
        Applies(categories: [.unsignedInteger, .signedInteger], bits: bits)
    }
    static func unsigned(bits: Set<Int>) -> Applies {
        Applies(categories: [.unsignedInteger], bits: bits)
    }
    static func all(bits: Set<Int>) -> Applies {
        Applies(categories: [.unsignedInteger, .signedInteger, .float], bits: bits)
    }
}

// A `tag` is not a parameter of the generated functions; it marks where Highway wants the tag
// in its own argument list.
enum Parameter {
    case tag
    case vector
    case indices
    case laneIndices
    case lookupIndices
    case mask
    case lane
    case constLanePointer
    case lanePointer
    case count
    case shiftAmount
    case laneAmount
    case outVector
    case fillVector
    case fillLane
    case whereMask
    case otherwiseVector

    /// The label of a parameter that only some overloads of an op take, and its rank among such
    /// parameters. Highway takes them first, as in `SlideUpLanesOr(lo, d, hi, amt)`, while Swift
    /// declares them after the ordinary ones, the lowest rank first.
    var overloading: (label: String, rank: Int)? {
        switch self {
        case .fillVector, .fillLane: return ("fillingWith", 1)
        case .whereMask: return ("where", 1)
        case .otherwiseVector: return ("otherwise", 2)
        default: return nil
        }
    }

    var isLaneIndices: Bool {
        self == .laneIndices || self == .lookupIndices
    }

    /// Where Swift declares a parameter among the others, the lowest rank first. Highway takes a
    /// lookup's table before its indices, while Swift takes the indices first.
    var swiftRank: Int {
        self == .lookupIndices ? -1 : overloading?.rank ?? 0
    }
}

enum UnorderedNaNs {
    case perLane
    case multiplyAdd
    case acrossLanes
}

enum ReturnType {
    case vector
    case mask
    case lane
    case count
    case index
    case boolean
    case void
}

// How much of a span the span form of a pointer op reads or writes, from the span's start.
// `first` is as many lanes as the span has, up to a vector, which a pointer op takes as `count`.
// An `aligned` op also needs the span to start at an address aligned to the vector size.
// A `table` is that many lanes, from an address aligned to their size, however many lanes a vector
// has.
enum SpanExtent {
    case vectors(Int, aligned: Bool = false)
    case first
    case table(lanes: Int)
}

// How many indices a lookup op accepts, as a number of lanes of a vector or a fixed number.
enum IndexCount {
    case fixed(Int)
    case lanes(Int)

    func expression(laneCount: String) -> String {
        switch self {
        case .fixed(let count): return String(count)
        case .lanes(1): return laneCount
        case .lanes(let multiple): return "\(multiple) * \(laneCount)"
        }
    }
}

// The indices a lookup op accepts: those which, as unsigned lanes, are below `count` once `offset`
// is subtracted from them, wrapping around. So an offset of 128 and a count of 144 accept 128
// through 255 and 0 through 15.
struct IndexContract {
    let offset: Int
    let count: IndexCount
    let message: String
    var isDefinedOnEmulation = true

    static let bytes = IndexContract(
        offset: 0,
        count: .fixed(16),
        message: "Byte index is negative or more than 15"
    )
    static let zeroingBytes = IndexContract(
        offset: 128,
        count: .fixed(144),
        message: "Byte index is 16 through 127"
    )
    static let lanes = IndexContract(
        offset: 0,
        count: .lanes(1),
        message: "Lane index is negative or at least as many as a vector has lanes",
        isDefinedOnEmulation: false
    )
    static func table(lanes: Int) -> IndexContract {
        IndexContract(
            offset: 0,
            count: .fixed(lanes),
            message: "Lane index is negative or at least as many as the table has lanes",
            isDefinedOnEmulation: false
        )
    }
    static let lanesOfTwoTables = IndexContract(
        offset: 0,
        count: .lanes(2),
        message: "Lane index is negative or at least twice as many as a vector has lanes"
    )
}

protocol WidthScaled {
    func at(width: Int) -> Self
}

extension Element: WidthScaled {}

struct WideningElements: WidthScaled {
    let narrow: Element
    let wide: Element

    func at(width: Int) -> WideningElements {
        WideningElements(narrow: narrow, wide: wide.at(width: width))
    }
}

struct TargetBodies<Input> {
    var neon: ((Input) -> String?)?
    var sve2_128: ((Input) -> String?)?
    var sve2_128Splat: ((Input) -> String?)?
    var avx3dl: ((Input) -> String?)?
    var avx3: ((Input) -> String?)?
    var avx2: ((Input) -> String?)?
    var sse4: ((Input) -> String?)?
    var ssse3: ((Input) -> String?)?
    var sse2: ((Input) -> String?)?

    var isEmpty: Bool {
        neon == nil && sve2_128 == nil && sve2_128Splat == nil && avx3dl == nil && avx3 == nil
            && avx2 == nil && sse4 == nil
            && ssse3 == nil && sse2 == nil
    }

    func body(at level: X86Level) -> ((Input) -> String?)? {
        switch level {
        case .avx3dl: return avx3dl
        case .avx3: return avx3
        case .avx2: return avx2
        case .sse4: return sse4
        case .ssse3: return ssse3
        case .sse2: return sse2
        }
    }
}

struct ConstantArgument {
    let name: String
    var cast = ""
    var applies: (Element) -> Bool = { _ in true }
    var vector = false
    var holds: ((Element) -> String)?
}

struct Op {
    let swiftName: String
    let highwayName: String
    let parameters: [Parameter]
    let returns: ReturnType
    let applies: Applies
    var documentation: String = ""
    let span: SpanExtent?
    let constantArgument: ConstantArgument?
    let indexContract: IndexContract?
    let unorderedNaNs: UnorderedNaNs?
    let targets: TargetBodies<Element>
    let spanTargets: TargetBodies<Element>
    let helpers: TargetBodies<Element>
    let outOfLineOnSVE: Applies?
    let portable: (Element) -> String

    init(
        _ swiftName: String,
        _ highwayName: String,
        _ parameters: [Parameter],
        _ returns: ReturnType,
        _ applies: Applies,
        _ documentation: String = "",
        span: SpanExtent? = nil,
        constantArgument: ConstantArgument? = nil,
        indexContract: IndexContract? = nil,
        unorderedNaNs: UnorderedNaNs? = nil,
        targets: TargetBodies<Element> = TargetBodies(),
        spanTargets: TargetBodies<Element> = TargetBodies(),
        helpers: TargetBodies<Element> = TargetBodies(),
        outOfLineOnSVE: Applies? = nil,
        portable: @escaping (Element) -> String
    ) {
        self.swiftName = swiftName
        self.highwayName = highwayName
        self.parameters = parameters
        self.returns = returns
        self.applies = applies
        self.documentation = documentation
        self.span = span
        self.constantArgument = constantArgument
        self.indexContract = indexContract
        self.unorderedNaNs = unorderedNaNs
        self.targets = targets
        self.spanTargets = spanTargets
        self.helpers = helpers
        self.outOfLineOnSVE = outOfLineOnSVE
        self.portable = portable
    }

    var operands: [Parameter] {
        parameters.filter { $0 != .tag }
    }

    /// The positions in `operands` of the parameters in the order Swift declares them.
    var swiftOrder: [Int] {
        let operands = self.operands
        return operands.indices.sorted {
            (operands[$0].swiftRank, $0) < (operands[$1].swiftRank, $1)
        }
    }

    /// `values`, one per operand in Highway's order, in the order Swift declares them.
    func swiftOrdered<Value>(_ values: [Value]) -> [Value] {
        swiftOrder.map { values[$0] }
    }

    /// `values`, one per operand in Swift's order, in the order Highway takes them.
    func highwayOrdered<Value>(_ values: [Value]) -> [Value] {
        var ordered = values
        for (position, index) in swiftOrder.enumerated() {
            ordered[index] = values[position]
        }
        return ordered
    }

    /// What tells this op from the overloads that share its `swiftName`, which the names of its
    /// C, reference and test functions are made of.
    var identifier: String {
        let labels = swiftOrdered(operands).compactMap { $0.overloading?.label }
        return swiftName + labels.map(uppercasedFirst).joined()
    }
}

func compoundLiteral(_ type: String, _ values: [String]) -> String {
    "(\(type)){\(values.joined(separator: ", "))}"
}

func splat(_ value: String, as type: String, lanes: Int) -> String {
    compoundLiteral(type, Array(repeating: value, count: lanes))
}

func iota(as type: String, lanes: Int) -> String {
    compoundLiteral(type, (0..<lanes).map(String.init))
}

func clampedCount(_ count: String = "count", to lanes: Int) -> String {
    "(\(count) < \(lanes) ? \(count) : \(lanes))"
}

func unsignedElement(bits: Int) -> Element {
    guard
        let unsigned = elements.first(where: { $0.category == .unsignedInteger && $0.bits == bits })
    else {
        fatalError("There is no unsigned element of \(bits) bits")
    }
    return unsigned
}

func unsignedElement(of element: Element) -> Element {
    unsignedElement(bits: element.bits)
}

func signedElement(of element: Element) -> Element {
    guard
        let signed = elements.first(where: {
            $0.category == .signedInteger && $0.bits == element.bits
        })
    else {
        fatalError("There is no signed element of \(element.bits) bits")
    }
    return signed
}

func laneIndexElement(of element: Element) -> Element {
    element.category == .float ? signedElement(of: element) : element
}

func operandElement(of parameter: Parameter, for element: Element) -> Element {
    parameter.isLaneIndices ? laneIndexElement(of: element) : element
}

func signedFirstLanesMask(for element: Element) -> String {
    let lanes = element.laneCount
    let offsets = iota(as: element.cMask, lanes: lanes)
    let unsigned = unsignedElement(of: element)
    let limit = "(\(element.cMask))\(repeatingVector("(\(unsigned.cType))n", of: unsigned))"
    return """
        const \(element.cMaskLane) n = (\(element.cMaskLane))\(clampedCount(to: lanes));
        const \(element.cMask) mask = \(limit) > \(offsets);
        """
}

func signedFirstLanes(for element: Element) -> String {
    "\(signedFirstLanesMask(for: element))\n\(maskResult("mask", for: element))"
}

func x86Avx3FirstLanes(for element: Element) -> String {
    let lanes = element.laneCount
    let bits = (value: x86FirstLanesBits(lanes: lanes), type: x86MaskType(lanes: lanes))
    let letter = x86LaneLetter(bits: element.bits)
    let mask = x86Builtin(
        "cvtmask2\(letter)\(x86Bits(element.width))",
        [bits],
        returning: element.cMask
    )
    return maskResult(mask, for: element)
}

func x86Int64FirstLanes(for element: Element) -> String {
    let lanes = element.laneCount
    let mask = element.cMask
    return """
        const \(element.cMaskLane) n = (\(element.cMaskLane))\(clampedCount(to: lanes));
        const \(mask) offsets = \(iota(as: mask, lanes: lanes));
        const \(mask) limit = \(splat("n", as: mask, lanes: lanes));
        \(x86Int64Comparison("limit", "offsets", for: element))
        """
}

func unsignedBits(_ operand: String, of element: Element) -> String {
    element.category == .unsignedInteger ? operand : "(\(element.cUnsignedVector))\(operand)"
}

func fromUnsignedBits(_ expression: String, of element: Element) -> String {
    element.category == .unsignedInteger ? expression : "(\(element.cVector))(\(expression))"
}

func repeatingVector(_ value: String, of element: Element) -> String {
    "(\(element.cVector))\(cFunctionName("repeating", element))(\(value))"
}

func vectorResult(_ expression: String, for element: Element) -> String {
    "return (\(element.cRawVector))(\(expression));"
}

func maskResult(_ expression: String, for element: Element) -> String {
    "return (\(element.cRawMask))(\(expression));"
}

func withoutContraction(_ statements: String) -> String {
    "{\n#pragma clang fp contract(off)\n\(indented(statements))\n}"
}

func unfusedMultiplyAdding(for element: Element) -> String {
    withoutContraction(vectorResult("a * b + c", for: element))
}

func arithmetic(
    _ symbol: String,
    _ first: String,
    _ second: String,
    for element: Element
) -> String {
    guard element.category == .signedInteger else { return "\(first) \(symbol) \(second)" }
    let unsigned = element.cUnsignedVector
    return "(\(element.cVector))((\(unsigned))\(first) \(symbol) (\(unsigned))\(second))"
}

func binaryArithmetic(_ symbol: String, for element: Element) -> String {
    vectorResult(arithmetic(symbol, "a", "b", for: element), for: element)
}

func vectorComparison(_ symbol: String, for element: Element) -> String {
    maskResult("(\(element.cMask))(a \(symbol) b)", for: element)
}

func bitSelect(_ mask: String, _ a: String, _ b: String, of element: Element) -> String {
    let unsignedMask = "(\(element.cUnsignedVector))\(mask)"
    let chosen = "(\(unsignedMask) & \(unsignedBits(a, of: element)))"
    let rest = "(~\(unsignedMask) & \(unsignedBits(b, of: element)))"
    return fromUnsignedBits("\(chosen) | \(rest)", of: element)
}

func infinity(of element: Element) -> String {
    element.bits == 32 ? "__builtin_inff()" : "__builtin_inf()"
}

func elementwiseExtremum(_ name: String, comparing symbol: String, for element: Element) -> String {
    guard element.category == .float else {
        return vectorResult("__builtin_elementwise_\(name)(a, b)", for: element)
    }
    let mask = element.cMask
    let ordered = "(\(mask))(a == a)"
    let unordered = "(\(mask))(a != a)"
    let constant = "__builtin_constant_p(__builtin_reduce_or((\(element.cUnsignedVector))b))"
    let number = "__builtin_elementwise_\(name)(first, b)"
    return """
        \(element.cVector) first = a;
        if (\(constant)) {
          first = \(bitSelect(unordered, "b", "a", of: element));
        }
        const \(mask) take = (\(mask))(first \(symbol) b) | ((\(mask))(b != b) & \(ordered));
        \(element.cVector) result = \(bitSelect("take", "first", "b", of: element));
        if (\(constant)) {
          \(element.cVector) source;
          for (size_t i = 0; i < \(element.laneCount); ++i) {
            source[i] = a[i] != a[i] ? b[i] : b[i] != b[i] ? a[i] : a[i] \(symbol) b[i] ? a[i] : b[i];
          }
          const \(mask) bySelect = ~((\(mask))(b < 0) | (\(mask))(b > 0));
          result = \(bitSelect("bySelect", "source", number, of: element));
        }
        \(vectorResult("result", for: element))
        """
}

func highestValue(of element: Element) -> String {
    switch element.category {
    case .float: return infinity(of: element)
    case .signedInteger: return "INT\(element.bits)_MAX"
    case .unsignedInteger: return "UINT\(element.bits)_MAX"
    }
}

func lowestValue(of element: Element) -> String {
    switch element.category {
    case .float: return "-\(infinity(of: element))"
    case .signedInteger: return "INT\(element.bits)_MIN"
    case .unsignedInteger: return "0"
    }
}

func reducedSum(for element: Element) -> String {
    let isSigned = element.category == .signedInteger
    let accumulator = isSigned ? element.cUnsignedLane : element.cType
    return """
        \(accumulator) sum = 0;
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          sum += a[i];
        }
        return \(isSigned ? "(\(element.cType))sum" : "sum");
        """
}

func reducedExtremum(
    comparing symbol: String,
    from start: String,
    for element: Element
) -> String {
    """
    \(element.cType) result = \(start);
    for (size_t i = 0; i < \(element.laneCount); ++i) {
      result = result \(symbol) a[i] ? result : a[i];
    }
    return result;
    """
}

func builtinReduction(_ name: String) -> String {
    "return __builtin_reduce_\(name)(a);"
}

func shiftedWithinWidth(_ symbol: String, for element: Element) -> String {
    let lane = element.cUnsignedLane
    let width = element.bits
    let inRange = splat("inRange", as: element.cUnsignedVector, lanes: element.laneCount)
    let shifted = "\(unsignedBits("a", of: element)) \(symbol) (bits & \(width - 1))"
    return """
        const \(lane) inRange = (\(lane))0 - (\(lane))((unsigned)bits < \(width));
        \(vectorResult(fromUnsignedBits("(\(shifted)) & \(inRange)", of: element), for: element))
        """
}

func scalarNaN(of element: Element) -> String {
    let bits = (UInt64(1) << UInt64(element.bits - 1)) - 1
    let literal = "(\(element.cUnsignedLane))0x\(String(bits, radix: 16))"
    return "__builtin_bit_cast(\(element.cType), \(literal))"
}

func reducedExtremumOrNaN(_ name: String, isNaN: String, for element: Element) -> String {
    let allFalse = cFunctionName("allFalse", element)
    let extremum = cFunctionName(name, element)
    let hasNoNaN = "\(allFalse)((\(element.cRawMask))\(isNaN))"
    return "return \(hasNoNaN) ? \(extremum)(\(rawName("a"))) : \(scalarNaN(of: element));"
}

func assumedAligned(_ pointer: String, for element: Element) -> String {
    "__builtin_assume_aligned(\(pointer), \(element.width))"
}

func loadedVector(from pointer: String, for element: Element) -> String {
    """
    \(element.cVector) v;
    __builtin_memcpy(&v, \(pointer), sizeof v);
    \(vectorResult("v", for: element))
    """
}

func storedVector(to pointer: String) -> String {
    "__builtin_memcpy(\(pointer), &a, sizeof a);"
}

func zeroedVector(of type: String) -> String {
    """
    \(type) v;
    __builtin_memset(&v, 0, sizeof v);
    """
}

func outVectorStore(_ channel: Int, from source: String? = nil) -> String {
    let name = source ?? "r\(channel)"
    return "__builtin_memcpy(v\(channel), &\(name), sizeof \(name));"
}

func outVectorStore(_ channel: Int, of value: String, for element: Element) -> String {
    """
    const \(element.cVector) out\(channel) = \(value);
    \(outVectorStore(channel, from: "out\(channel)"))
    """
}

func loadInterleaved(channels: Int, for element: Element) -> String {
    let names = (0..<channels).map { "buf\($0)" }
    let declarations = names.map {
        "\(element.cType) \($0)[\(element.laneCount)] __attribute__((aligned(\(element.width))));"
    }
    let loads = names.map { "  \($0)[i] = *from++;" }
    let load = cFunctionName("loadAligned", element)
    let stores = names.enumerated().map { channel, name in
        element.bits >= 32
            ? outVectorStore(channel, from: name)
            : outVectorStore(channel, of: "(\(element.cVector))\(load)(\(name))", for: element)
    }
    return """
        \(declarations.joined(separator: "\n"))
        for (size_t i = 0; i < \(element.laneCount); ++i) {
        \(loads.joined(separator: "\n"))
        }
        \(stores.joined(separator: "\n"))
        """
}

func storeInterleaved(channels: Int, for element: Element) -> String {
    let names = ["a", "b", "c", "d"].prefix(channels)
    if element.bits == 64 {
        let lanes = (0..<element.laneCount).flatMap { lane in
            names.map { "const \(element.cType) \($0)\(lane) = \($0)[\(lane)];" }
        }
        let stores = (0..<element.laneCount).flatMap { lane in
            names.map { "*to++ = \($0)\(lane);" }
        }
        return (lanes + stores).joined(separator: "\n")
    }
    let stores = names.map { name in
        "  *to++ = \(name)[i];"
    }
    return """
        #pragma clang loop unroll(full)
        for (size_t i = 0; i < \(element.laneCount); ++i) {
        \(stores.joined(separator: "\n"))
        }
        """
}

struct RawVector {
    let name: String
    let type: String
    let attribute: String
}

func neonVector(_ suffix: String) -> String {
    "cvectorization_ops_neon_\(suffix)"
}

func sveVector(_ suffix: String) -> String {
    "cvectorization_ops_sve_\(suffix)"
}

func x86Vector(_ suffix: String) -> String {
    "cvectorization_ops_x86_\(suffix)"
}

func x86Block(_ suffix: String) -> String {
    "cvectorization_ops_x86_block_\(suffix)"
}

let x86IfThenElseName = "cvectorization_ops_x86_if_then_else"

func x86GreaterThanName(bits: Int) -> String {
    "cvectorization_ops_x86_greater_than_i\(bits)"
}

func x86AsFloatName(bits: Int) -> String {
    "cvectorization_ops_x86_as_f\(bits)"
}

let neonVectors: [RawVector] = [
    RawVector(name: neonVector("i8x8"), type: "int8_t", attribute: "neon_vector_type(8)"),
    RawVector(name: neonVector("i8"), type: "int8_t", attribute: "neon_vector_type(16)"),
    RawVector(name: neonVector("f32"), type: "float", attribute: "neon_vector_type(4)"),
    RawVector(name: neonVector("f64"), type: "double", attribute: "neon_vector_type(2)"),
]

let sveVectorBits = 128

let sveVectors: [RawVector] = elements.map { element in
    RawVector(
        name: sveVector(element.cSuffix),
        type: sveType(of: element),
        attribute: "arm_sve_vector_bits(\(sveVectorBits))"
    )
}

let x86Lanes: [(suffix: String, lane: String)] = [
    ("i8", "char"),
    ("i16", "short"),
    ("i32", "int"),
    ("i64", "long long"),
    ("f32", "float"),
    ("f64", "double"),
]

let x86Vectors: [RawVector] = x86Lanes.flatMap { suffix, lane in
    [
        RawVector(
            name: x86Vector(suffix),
            type: lane,
            attribute: "vector_size(CVECTORIZATION_OPS_VECTOR_BYTES)"
        ),
        RawVector(name: x86Block(suffix), type: lane, attribute: "vector_size(16)"),
    ]
}

func x86RawType(of element: Element) -> String {
    x86Vector(element.hasOpaqueVector ? "i64" : element.cSuffix)
}

func x86RawBlockType(of element: Element) -> String {
    x86Block(element.hasOpaqueVector ? "i64" : element.cSuffix)
}

func neonTypeCode(of element: Element) -> Int {
    let quad = 32
    switch element.category {
    case .unsignedInteger: return quad + 16 + (element.bits / 8).trailingZeroBitCount
    case .signedInteger: return quad + (element.bits / 8).trailingZeroBitCount
    case .float: return quad + (element.bits == 32 ? 9 : 10)
    }
}

func neonBuiltin(
    _ name: String,
    _ arguments: [String],
    code: Int,
    for element: Element
) -> String {
    let operands = arguments.map { "(\(neonVector("i8")))\($0)" } + [String(code)]
    return "(\(element.cVector))__builtin_neon_\(name)(\(operands.joined(separator: ", ")))"
}

func neonShift(negated: Bool, for element: Element) -> String {
    let lanes = element.laneCount
    let count = splat("(\(element.cUnsignedLane))bits", as: element.cUnsignedVector, lanes: lanes)
    let amounts = ["a", negated ? "(-count)" : "count"]
    let shifted = neonBuiltin("vshlq_v", amounts, code: neonTypeCode(of: element), for: element)
    return """
        const \(element.cUnsignedVector) count = \(count);
        \(vectorResult(shifted, for: element))
        """
}

func neonExtremum(
    _ name: String,
    of operands: [String] = ["a", "b"],
    for element: Element
) -> String {
    guard element.bits < 64 || element.category == .float else {
        let chosen = name == "min" ? (first: "b", second: "a") : (first: "a", second: "b")
        let selected = bitSelect("mask", chosen.first, chosen.second, of: element)
        return """
            const \(element.cMask) mask = (\(element.cMask))(b < a);
            \(vectorResult(selected, for: element))
            """
    }
    let instruction = element.category == .float ? "v\(name)nmq_v" : "v\(name)q_v"
    let code = neonTypeCode(of: element)
    return vectorResult(
        neonBuiltin(instruction, operands, code: code, for: element),
        for: element
    )
}

func multiplying64(
    for element: Element,
    widening product: (_ first: String, _ second: String) -> String
) -> String {
    let words = "cvectorization_ops_vector_u32"
    func widened(_ first: String, _ second: String, into result: String) -> String {
        "const \(words) \(result) = (\(words))\(product(first, second));"
    }
    func high(_ operand: String) -> String {
        "(\(words))(\(unsignedBits(operand, of: element)) >> 32)"
    }
    let unsigned = element.cUnsignedVector
    return """
        const \(words) x = (\(words))a;
        const \(words) y = (\(words))b;
        \(widened("x", "y", into: "lolo"))
        const \(words) yHigh = \(high("b"));
        \(widened("x", "yHigh", into: "lohi"))
        const \(words) xHigh = \(high("a"));
        \(widened("xHigh", "y", into: "hilo"))
        const \(words) hi = (\(words))((\(unsigned))(lohi + hilo) << 32);
        \(vectorResult(fromUnsignedBits("(\(unsigned))(lolo + hi)", of: element), for: element))
        """
}

func neonMultiplying64(for element: Element) -> String {
    let halves = neonVector("i8x8")
    func evens(_ operand: String) -> String {
        "(\(halves))__builtin_shufflevector(\(operand), \(operand), 0, 2)"
    }
    return multiplying64(for: element) { first, second in
        let product = "__builtin_neon_vmull_v(\(evens(first)), \(evens(second)), 51)"
        return "(\(element.cUnsignedVector))\(product)"
    }
}

func x86Multiplying64(for element: Element) -> String {
    multiplying64(for: element) { first, second in
        x86Builtin(
            "pmuludq\(x86Bits(element.width))",
            [first, second],
            as: "i32",
            returning: element.cUnsignedVector
        )
    }
}

func neonRoundedAverage(for element: Element) -> String {
    let code = neonTypeCode(of: element)
    return vectorResult(
        neonBuiltin("vrhaddq_v", ["a", "b"], code: code, for: element),
        for: element
    )
}

func neonSaturatingSubtraction(for element: Element) -> String {
    let code = neonTypeCode(of: element)
    return vectorResult(
        neonBuiltin("vqsubq_v", ["a", "b"], code: code, for: element),
        for: element
    )
}

func neonReduction(_ name: String, for element: Element) -> String? {
    guard element.category == .float else { return nil }
    return "return __builtin_neon_\(name)_\(element.cSuffix)((\(neonVector(element.cSuffix)))a);"
}

func neonReducedExtremumOrNaN(_ name: String, for element: Element) -> String? {
    guard element.category == .float else { return nil }
    let reduced = "__builtin_neon_\(name)_\(element.cSuffix)((\(neonVector(element.cSuffix)))a)"
    return """
        const \(element.cType) reduced = \(reduced);
        return reduced != reduced ? \(scalarNaN(of: element)) : reduced;
        """
}

func neonPairExtremum(comparing symbol: String, for element: Element) -> String? {
    guard element.bits == 64, element.category != .float else { return nil }
    return "return a[0] \(symbol) a[1] ? a[0] : a[1];"
}

func neonTableLookup(_ bytes: String, _ indices: String, for element: Element) -> String {
    neonBuiltin("vqtbl1q_v", [bytes, indices], code: 48, for: element)
}

func neonTwoTablesLookup(
    _ first: String,
    _ second: String,
    _ indices: String,
    for element: Element
) -> String {
    neonBuiltin("vqtbl2q_v", [first, second, indices], code: 48, for: element)
}

func lookupBroadcastBytes(lane bytes: Int, width: Int) -> [UInt8] {
    (0..<width).map { UInt8(($0 % 16) / bytes * bytes) }
}

func lookupByteOffsets(lane bytes: Int, width: Int) -> [UInt8] {
    (0..<width).map { UInt8($0 % bytes) }
}

func neonLaneByteIndices(for element: Element) -> (statements: String, indices: String) {
    guard element.bits > 8 else { return ("", "indices") }
    let bytes = element.bits / 8
    let broadcast = lookupBroadcastBytes(lane: bytes, width: element.width).map(String.init)
    let offsets = lookupByteOffsets(lane: bytes, width: element.width).map(String.init)
    let byte = unsignedElement(bits: 8)
    let type = byte.cVector
    let lanes = neonBuiltin("vqtbl1q_v", ["indices", "broadcast"], code: 48, for: byte)
    return (
        """
        const \(type) broadcast = {\(broadcast.joined(separator: ", "))};
        const \(type) offsets = {\(offsets.joined(separator: ", "))};
        const \(type) laneIndices = \(lanes);
        const \(type) byteIndices = (laneIndices << \(bytes.trailingZeroBitCount)) + offsets;
        """,
        "byteIndices"
    )
}

func neonTableLookupLanes(for element: Element) -> String {
    let lookup = neonLaneByteIndices(for: element)
    let table = vectorResult(neonTableLookup("a", lookup.indices, for: element), for: element)
    return [lookup.statements, table].filter { !$0.isEmpty }.joined(separator: "\n")
}

func neonTwoTablesLookupLanes(for element: Element) -> String {
    let lookup = neonLaneByteIndices(for: element)
    let tables = neonTwoTablesLookup("a", "b", lookup.indices, for: element)
    return [lookup.statements, vectorResult(tables, for: element)]
        .filter { !$0.isEmpty }.joined(separator: "\n")
}

let neonNibbles = """
    typedef uint16_t wide_vector __attribute__((vector_size(16)));
    typedef uint8_t narrow_vector __attribute__((vector_size(8)));
    const narrow_vector narrowed = __builtin_convertvector((wide_vector)mask >> 4, narrow_vector);
    const uint64_t nibbles = __builtin_bit_cast(uint64_t, narrowed);
    """

func neonFirstTrueIndex(for element: Element) -> String {
    """
    \(neonNibbles)
    return nibbles == 0 ? -1 : (intptr_t)(__builtin_ctzll(nibbles) / \(element.bits / 2));
    """
}

let sveAllPattern = 31

func sveType(of element: Element) -> String {
    switch element.category {
    case .unsignedInteger: return "__SVUint\(element.bits)_t"
    case .signedInteger: return "__SVInt\(element.bits)_t"
    case .float: return "__SVFloat\(element.bits)_t"
    }
}

func sveSuffix(of element: Element) -> String {
    element.category == .signedInteger ? "s\(element.bits)" : element.cSuffix
}

func sveBuiltin(
    _ name: String,
    _ arguments: [String],
    for element: Element,
    predication: String? = nil
) -> String {
    let parts = [name, sveSuffix(of: element)] + (predication.map { [$0] } ?? [])
    return "__builtin_sve_sv\(parts.joined(separator: "_"))(\(arguments.joined(separator: ", ")))"
}

func sveOperand(_ name: String, for element: Element, splat: Bool = false) -> String {
    let operand = "(\(sveVector(element.cSuffix)))\(name)"
    guard splat, isInteger64(element) else { return operand }
    let duplicated = sveBuiltin("dup_n", ["\(name)[0]"], for: element)
    let condition = sveSplatCondition(name, nil, for: element)
    return "(\(condition) ? \(duplicated) : (\(sveType(of: element)))\(operand))"
}

func sveResult(_ call: String, for element: Element) -> String {
    "(\(element.cVector))(\(sveVector(element.cSuffix)))\(call)"
}

func sveAllLanes(of element: Element) -> String {
    "__builtin_sve_svptrue_pat_b\(element.bits)(\(sveAllPattern))"
}

func sveShift(_ instruction: String, for element: Element) -> String {
    let arguments = [
        sveAllLanes(of: element),
        sveOperand("a", for: element, splat: true),
        "(\(element.cUnsignedLane))bits",
    ]
    let shifted = sveBuiltin("\(instruction)_n", arguments, for: element, predication: "x")
    return vectorResult(sveResult(shifted, for: element), for: element)
}

enum SveImmediate {
    case arithmetic
    case signed
    case unsigned
    case comparison
}

func sveImmediateFits(_ lane: String, _ immediate: SveImmediate, for element: Element) -> String? {
    let narrow = element.bits == 16 || element.bits == 32
    switch immediate {
    case .comparison:
        return element.category == .signedInteger
            ? "(\(lane) >= -16 && \(lane) <= 15)" : "(\(lane) <= 127)"
    case .arithmetic where narrow:
        let value = "(\(element.cUnsignedLane))\(lane)"
        return "(\(value) <= 255 || ((\(value) & 255) == 0 && \(value) <= 65280))"
    case .signed where narrow:
        let value = "(\(element.cMaskLane))\(lane)"
        return "(\(value) >= -128 && \(value) <= 127)"
    case .unsigned where narrow:
        return "(\(element.cUnsignedLane))\(lane) <= 255"
    default:
        return nil
    }
}

func sveSplatCondition(
    _ name: String,
    _ immediate: SveImmediate?,
    for element: Element
) -> String {
    let splat = "\(cFunctionName("sveSplat", element))(\(name))"
    guard let immediate, let fits = sveImmediateFits("\(name)[0]", immediate, for: element) else {
        return splat
    }
    return "\(splat) && \(fits)"
}

func sveSplatBranch(
    _ name: String,
    _ immediate: SveImmediate?,
    for element: Element,
    _ body: (String) -> String
) -> String {
    """
    if (\(sveSplatCondition(name, immediate, for: element))) {
      \(body(sveBuiltin("dup_n", ["\(name)[0]"], for: element)))
    }
    """
}

func sveSplatBinary(
    _ name: String,
    _ immediate: SveImmediate?,
    operands: (first: String, second: String) = ("a", "b"),
    commutative: Bool = true,
    splattingFirst: Bool = true,
    predicated: Bool = true,
    for element: Element
) -> String? {
    guard element.category != .float else { return nil }
    func combined(_ first: String, _ second: String) -> String {
        let arguments = (predicated ? [sveAllLanes(of: element)] : []) + [first, second]
        let call = sveBuiltin(name, arguments, for: element, predication: predicated ? "x" : nil)
        return vectorResult(sveResult(call, for: element), for: element)
    }
    let first = sveOperand(operands.first, for: element)
    let second = sveOperand(operands.second, for: element)
    let branches = [
        sveSplatBranch(operands.second, immediate, for: element) { combined(first, $0) },
        splattingFirst
            ? sveSplatBranch(operands.first, immediate, for: element) {
                commutative ? combined(second, $0) : combined($0, second)
            } : nil,
    ]
    return branches.compactMap { $0 }.joined(separator: "\n")
}

func sveConstantFunction(for element: Element) -> String {
    let bits = element.category == .float ? "(\(element.cUnsignedVector))v" : "v"
    let function = cFunction(
        returns: "bool",
        name: cFunctionName("sveConstant", element),
        parameters: ["\(element.cVector) v"],
        body: "return __builtin_constant_p(__builtin_reduce_or(\(bits)));"
    )
    return "#if \(sve2_128Condition)\n\(function)#endif\n"
}

func sveReduction(_ name: String, for element: Element) -> String? {
    guard isInteger64(element) else { return nil }
    let reduced = sveBuiltin(
        name,
        [sveAllLanes(of: element), sveOperand("a", for: element)],
        for: element
    )
    return "return \(reduced);"
}

func sveReversed(for element: Element) -> String? {
    guard element.bits < 64 else { return nil }
    let reversed = sveBuiltin("rev", [sveOperand("a", for: element)], for: element)
    return vectorResult(sveResult(reversed, for: element), for: element)
}

func sveLaneIndices(for element: Element) -> String {
    sveOperand("indices", for: unsignedElement(of: element))
}

func sveTableLookupLanes(for element: Element) -> String {
    let operands = [sveOperand("a", for: element), sveLaneIndices(for: element)]
    let lookup = sveBuiltin("tbl", operands, for: element)
    return vectorResult(sveResult(lookup, for: element), for: element)
}

func sveTwoTablesLookupLanes(for element: Element) -> String {
    let operands = [sveOperand("a", for: element), sveOperand("b", for: element)]
    let tables = sveBuiltin("create2", operands, for: element)
    let lookup = sveBuiltin("tbl2", [tables, sveLaneIndices(for: element)], for: element)
    return vectorResult(sveResult(lookup, for: element), for: element)
}

func sveComparisonSplat(_ name: String, mirrored: String, for element: Element) -> String? {
    guard isInteger64(element) else { return nil }
    let unsigned = unsignedElement(of: element)
    func selected(_ comparison: String) -> String {
        let lanes = sveBuiltin(
            "dup_n",
            [comparison, "(\(unsigned.cUnsignedLane))-1"],
            for: unsigned,
            predication: "z"
        )
        return maskResult(
            "(\(element.cMask))(\(sveVector(unsigned.cSuffix)))\(lanes)",
            for: element
        )
    }
    let all = sveAllLanes(of: element)
    return [
        sveSplatBranch("b", .comparison, for: element) {
            selected(sveBuiltin(name, [all, sveOperand("a", for: element), $0], for: element))
        },
        sveSplatBranch("a", .comparison, for: element) {
            selected(sveBuiltin(mirrored, [all, sveOperand("b", for: element), $0], for: element))
        },
    ].joined(separator: "\n")
}

func sveAllFalse(for element: Element) -> String? {
    guard element.bits == 64 else { return nil }
    let all = sveAllLanes(of: element)
    let unsigned = unsignedElement(of: element)
    let nonzero = sveBuiltin(
        "cmpne_n",
        [all, "(\(sveVector(unsigned.cSuffix)))mask", "0"],
        for: unsigned
    )
    return "return !__builtin_sve_svptest_any(\(all), \(nonzero));"
}

func sveSplatFunction(for element: Element) -> String {
    let function = cFunction(
        returns: "bool",
        name: cFunctionName("sveSplat", element),
        parameters: ["\(element.cVector) v"],
        body: """
            const bool splat = __builtin_reduce_and(v == v[0]) != 0;
            return __builtin_constant_p(splat) && splat;
            """
    )
    return "#if \(sve2_128Condition)\n\(function)#endif\n"
}

func sveBinary(_ name: String, for element: Element) -> String {
    let operands = [sveOperand("a", for: element), sveOperand("b", for: element)]
    let combined = sveBuiltin(
        name,
        [sveAllLanes(of: element)] + operands,
        for: element,
        predication: "x"
    )
    let plain = vectorResult(sveResult(combined, for: element), for: element)
    let bodies = [sveSplatBinary(name, nil, for: element), plain].compactMap { $0 }
    return bodies.joined(separator: "\n")
}

func sveAndXor(for element: Element) -> String? {
    guard element.bits == 64 else { return nil }
    let exclusive = "\(cFunctionName("bitwiseXor", element))(rawB, rawC)"
    return "return \(cFunctionName("bitwiseAnd", element))(rawA, \(exclusive));"
}

func sveMaskedBitwiseOtherwise(_ name: String, for element: Element) -> String? {
    guard element.bits == 64 else { return nil }
    let operation = "\(cFunctionName(name, element))(rawA, rawB)"
    return "return \(cFunctionName("selecting", element))(rawMask, \(operation), rawOtherwise);"
}

func sveBitwiseSplat(
    _ name: String,
    operands: (first: String, second: String) = ("a", "b"),
    commutative: Bool = true,
    splattingFirst: Bool = true,
    for element: Element
) -> String? {
    guard element.bits == 8 || element.bits == 64 else { return nil }
    return sveSplatBinary(
        name,
        nil,
        operands: operands,
        commutative: commutative,
        splattingFirst: splattingFirst,
        for: element
    )
}

func sveExtremumImmediate(for element: Element) -> SveImmediate {
    element.category == .signedInteger ? .signed : .unsigned
}

enum SveBlockedLane {
    case notANumber
    case one
    case minusOne
    case zero
    case minusZero
    case infinity
    case minusInfinity
}

func sveBlockedLiteral(_ lane: SveBlockedLane, for element: Element) -> String? {
    let suffix = element.bits == 32 ? "f" : ""
    switch lane {
    case .notANumber: return nil
    case .one: return "1.0\(suffix)"
    case .minusOne: return "-1.0\(suffix)"
    case .zero: return "0.0\(suffix)"
    case .minusZero: return "-0.0\(suffix)"
    case .infinity: return infinity(of: element)
    case .minusInfinity: return "-\(infinity(of: element))"
    }
}

struct SveBlockedLanes {
    let first: [SveBlockedLane]
    let second: [SveBlockedLane]

    static func both(_ lanes: [SveBlockedLane]) -> SveBlockedLanes {
        SveBlockedLanes(first: lanes, second: lanes)
    }
}

func sveBlockedCondition(
    _ lanes: [SveBlockedLane],
    of operand: String,
    for element: Element
) -> [String] {
    lanes.map { lane in
        guard let literal = sveBlockedLiteral(lane, for: element) else {
            return "\(cFunctionName("sveConstantNaN", element))(\(operand))"
        }
        return "\(cFunctionName("sveConstantLane", element))(\(operand), \(literal))"
    }
}

func sveConstantNaNFunction(for element: Element) -> String {
    let function = cFunction(
        returns: "bool",
        name: cFunctionName("sveConstantNaN", element),
        parameters: ["\(element.cVector) v"],
        body: """
            const bool found = __builtin_reduce_or(v != v) != 0;
            return __builtin_constant_p(found) && found;
            """
    )
    return "#if \(sve2_128Condition)\n\(function)#endif\n"
}

func sveConstantNumbersFunction(for element: Element) -> String {
    let function = cFunction(
        returns: "bool",
        name: cFunctionName("sveConstantNumbers", element),
        parameters: ["\(element.cVector) a", "\(element.cVector) b"],
        body: """
            const bool found = __builtin_reduce_or((a != a) | (b != b)) != 0;
            return __builtin_constant_p(found) && !found;
            """
    )
    return "#if \(sve2_128Condition)\n\(function)#endif\n"
}

func sveConstantLaneFunction(for element: Element) -> String {
    let laneBits = "__builtin_bit_cast(\(element.cUnsignedLane), lane)"
    let function = cFunction(
        returns: "bool",
        name: cFunctionName("sveConstantLane", element),
        parameters: ["\(element.cVector) v", "\(element.cType) lane"],
        body: """
            const bool found = __builtin_reduce_or(\(unsignedBits("v", of: element)) == \(laneBits)) != 0;
            return __builtin_constant_p(found) && found;
            """
    )
    return "#if \(sve2_128Condition)\n\(function)#endif\n"
}

func sveConstantBarrier(
    blocking blocked: SveBlockedLanes,
    for element: Element,
    _ operation: (_ first: String, _ second: String) -> String
) -> String {
    let conditions =
        sveBlockedCondition(blocked.first, of: "a", for: element)
        + sveBlockedCondition(blocked.second, of: "b", for: element)
    let numbers = "\(cFunctionName("sveConstantNumbers", element))(a, b)"
    return """
        if (!\(numbers) && (\(conditions.joined(separator: " || ")))) {
          \(element.cVector) first = a;
          \(element.cVector) second = b;
          __asm__("" : "+w"(first), "+w"(second));
          \(operation("first", "second"))
        }
        \(operation("a", "b"))
        """
}

func sveConstantExtremum(
    _ name: String,
    blocking lane: SveBlockedLane,
    for element: Element
) -> String {
    sveConstantBarrier(blocking: .both([.notANumber, lane]), for: element) {
        neonExtremum(name, of: [$0, $1], for: element)
    }
}

func sveConstantArithmetic(
    _ symbol: String,
    blocking blocked: SveBlockedLanes,
    for element: Element
) -> String? {
    guard element.category == .float else { return nil }
    return sveConstantBarrier(blocking: blocked, for: element) {
        vectorResult(arithmetic(symbol, $0, $1, for: element), for: element)
    }
}

func sveExtremum(_ name: String, blocking lane: SveBlockedLane, for element: Element) -> String? {
    guard element.category != .float else {
        return sveConstantExtremum(name, blocking: lane, for: element)
    }
    guard element.bits == 64 else { return nil }
    return sveBinary(name, for: element)
}

func sveMultiplyAdding(for element: Element) -> String {
    let (mul, x, add) = ("a", "b", "c")
    let arguments = [sveAllLanes(of: element)] + [x, mul, add].map { sveOperand($0, for: element) }
    let fused = sveBuiltin("mad", arguments, for: element, predication: "x")
    return vectorResult(sveResult(fused, for: element), for: element)
}

func svePredicated(_ name: String, _ operands: [String], for element: Element) -> String {
    sveBuiltin(name, ["all"] + operands, for: element, predication: "x")
}

func sveMultiplyAddingLow52Bits(for element: Element) -> String {
    func predicated(_ name: String, _ operands: String...) -> String {
        svePredicated(name, operands, for: element)
    }
    let a = sveOperand("a", for: element, splat: true)
    let b = sveOperand("b", for: element, splat: true)
    let c = sveOperand("c", for: element, splat: true)
    let mask = (UInt64(1) << UInt64(multiplyAddedBits)) - 1
    let kept = predicated(
        "and",
        predicated("mul", a, b),
        sveBuiltin("dup_n", ["0x\(String(mask, radix: 16))"], for: element)
    )
    let sum = predicated("add", kept, c)
    return """
        const __SVBool_t all = \(sveAllLanes(of: element));
        \(vectorResult(sveResult(sum, for: element), for: element))
        """
}

func sveMultiplyAddingHigh52Bits(for element: Element) -> String {
    func predicated(_ name: String, _ operands: String...) -> String {
        svePredicated(name, operands, for: element)
    }
    let a = sveOperand("a", for: element, splat: true)
    let b = sveOperand("b", for: element, splat: true)
    let c = sveOperand("c", for: element, splat: true)
    let low = predicated("lsr_n", predicated("mul", a, b), "\(multiplyAddedBits)")
    let high = predicated("lsl_n", predicated("mulh", a, b), "\(element.bits - multiplyAddedBits)")
    let sum = predicated("add", predicated("orr", low, high), c)
    return """
        const __SVBool_t all = \(sveAllLanes(of: element));
        \(vectorResult(sveResult(sum, for: element), for: element))
        """
}

func sveActiveLanes(_ count: String, for element: Element) -> String {
    "__builtin_sve_svwhilelt_b\(element.bits)_u32(0, (uint32_t)(\(count)))"
}

func sveClampedLanes(for element: Element) -> String {
    "__builtin_sve_svwhilelt_b\(element.bits)_u64(0, (uint64_t)count)"
}

func sveFirstLanes(for element: Element) -> String {
    let unsigned = unsignedElement(of: element)
    let selected = sveBuiltin(
        "sel",
        [
            sveActiveLanes("count", for: element),
            sveBuiltin("dup_n", ["(\(unsigned.cType))-1"], for: unsigned),
            sveBuiltin("dup_n", ["0"], for: unsigned),
        ],
        for: unsigned
    )
    return maskResult("(\(element.cMask))(\(sveVector(unsigned.cSuffix)))\(selected)", for: element)
}

func sveSlideUp(filling: Bool, for element: Element) -> String {
    let fill =
        filling
        ? sveOperand("fill", for: element, splat: true) : sveBuiltin("dup_n", ["0"], for: element)
    let slid = sveBuiltin(
        "splice",
        [sveActiveLanes("lanes", for: element), fill, sveOperand("a", for: element, splat: true)],
        for: element
    )
    return vectorResult(sveResult(slid, for: element), for: element)
}

func sveIota(for element: Element) -> String? {
    guard element.category != .float else { return nil }
    return vectorResult(
        sveResult(sveBuiltin("index", ["value", "1"], for: element), for: element),
        for: element
    )
}

func sveExtendingLoad(_ active: String, from narrow: Element, to wide: Element) -> String {
    let signedness = wide.category == .signedInteger ? "s" : "u"
    let width = ["b", "h", "w"][narrow.bits.trailingZeroBitCount - 3]
    let load = sveBuiltin("ld1\(signedness)\(width)", [active, "from"], for: wide)
    return vectorResult(sveResult(load, for: wide), for: wide)
}

func sveLoadFirstWideningToFloat(from narrow: Element, to wide: Element) -> String {
    let active = sveClampedLanes(for: wide)
    let words = unsignedElement(of: wide)
    let bits = unsignedElement(of: narrow)
    let load = sveBuiltin("ld1uw", [active, "(const \(bits.cType)*)from"], for: words)
    let loaded = "__builtin_sve_reinterpret_f32_u64(\(load))"
    let converted = "__builtin_sve_svcvt_f64_f32_x(\(sveAllLanes(of: wide)), \(loaded))"
    return """
        if (__builtin_constant_p(count)) {
        \(indented(neonLoadFirstWidening(from: narrow, to: wide)))
        }
        \(vectorResult(sveResult(converted, for: wide), for: wide))
        """
}

func sveLoadFirstWidening(from narrow: Element, to wide: Element) -> String? {
    guard wide.category != .float else {
        return sveLoadFirstWideningToFloat(from: narrow, to: wide)
    }
    return sveExtendingLoad(sveClampedLanes(for: wide), from: narrow, to: wide)
}

func sveLoadFirst(for element: Element, spanned: Bool = false) -> String {
    let active = spanned ? sveClampedLanes(for: element) : sveActiveLanes("count", for: element)
    let loaded = sveBuiltin("ld1", [active, "from"], for: element)
    return vectorResult(sveResult(loaded, for: element), for: element)
}

func sveStoreFirst(for element: Element) -> String {
    let stored = sveBuiltin(
        "st1",
        [sveClampedLanes(for: element), "to", sveOperand("a", for: element)],
        for: element
    )
    return "\(stored);"
}

enum ArmLevel: Int {
    case neon = 1
    case sve2_128
}

enum X86Level: Int, CaseIterable, Comparable {
    case sse2 = 1
    case ssse3
    case sse4
    case avx2
    case avx3
    case avx3dl

    static func < (first: X86Level, second: X86Level) -> Bool {
        first.rawValue < second.rawValue
    }

    var width: Int {
        switch self {
        case .sse2, .ssse3, .sse4: return 16
        case .avx2: return 32
        case .avx3, .avx3dl: return 64
        }
    }

    var inherited: [X86Level] {
        X86Level.allCases.filter { $0 <= self && $0.width == width }.reversed()
    }
}

enum SlideDirection: String {
    case up
    case down
}

enum Reduction {
    case sum
    case minimum
    case maximum

    var combiningOp: String {
        switch self {
        case .sum: return "adding"
        case .minimum: return "minimum"
        case .maximum: return "maximum"
        }
    }
}

func prefixed(_ prefix: String, _ name: String) -> String {
    prefix.isEmpty ? name : "\(prefix)\(uppercasedFirst(name))"
}

func x86Builtin(
    _ name: String,
    _ operands: [(value: String, type: String)],
    returning type: String
) -> String {
    let casts = operands.map { "(\($0.type))\($0.value)" }
    return "(\(type))__builtin_ia32_\(name)(\(casts.joined(separator: ", ")))"
}

func x86Builtin(
    _ name: String,
    _ arguments: [String],
    as suffix: String,
    returning type: String
) -> String {
    x86Builtin(name, arguments.map { (value: $0, type: x86Vector(suffix)) }, returning: type)
}

func x86Bits(_ width: Int) -> String {
    "\(width * 8)"
}

func x86UnsuffixedBits(_ width: Int) -> String {
    width == 16 ? "" : x86Bits(width)
}

let x86CurrentRounding = 4

func x86LaneLetter(bits: Int) -> String {
    guard let letter = [8: "b", 16: "w", 32: "d", 64: "q"][bits] else {
        fatalError("There is no x86 letter for \(bits)-bit lanes")
    }
    return letter
}

func x86LaneSuffix(of element: Element) -> String {
    element.category == .float ? element.cSuffix : "i\(element.bits)"
}

func x86LaneType(of element: Element) -> String {
    guard let lane = x86Lanes.first(where: { $0.suffix == x86LaneSuffix(of: element) })?.lane else {
        fatalError("There is no x86 lane type of \(element.swiftType)")
    }
    return lane
}

func x86MaskedPointee(of register: String, width: Int, for element: Element) -> String {
    width == 64 && (element.category == .float || element.bits >= 32)
        ? x86LaneType(of: element) : register
}

func x86MaskType(lanes: Int) -> String {
    switch lanes {
    case 64: return "unsigned long long"
    case 32: return "unsigned int"
    case 16: return "unsigned short"
    default: return "unsigned char"
    }
}

func x86FirstLanesBits(lanes: Int, count: String = "count", all: String = "~0ull") -> String {
    "__builtin_ia32_bzhi_di(\(all), \(clampedCount(count, to: lanes)))"
}

func x86MaskedAccessName(_ access: String, width: Int, for element: Element) -> String {
    let bits = x86Bits(width)
    guard element.category != .float else {
        return "\(access)u\(element.bits == 32 ? "ps" : "pd")\(bits)_mask"
    }
    guard let suffix = [8: "qi", 16: "hi", 32: "si", 64: "di"][element.bits] else {
        fatalError("There is no x86 masked access of \(element.bits)-bit lanes")
    }
    return "\(access)dqu\(suffix)\(bits)_mask"
}

func x86ShiftCount(_ amount: String) -> String {
    compoundLiteral(x86Block("i32"), [amount, "0", "0", "0"])
}

func x86ShiftName(_ instruction: String, laneBits: Int) -> String {
    guard let suffix = [16: "w", 32: "d", 64: "q"][laneBits] else {
        fatalError("There is no x86 shift of \(laneBits)-bit lanes")
    }
    return "\(instruction)\(suffix)"
}

func x86RegisterShift(
    _ instruction: String,
    _ operand: String,
    by amount: String,
    laneBits: Int,
    width: Int,
    returning type: String
) -> String {
    let name = "\(x86ShiftName(instruction, laneBits: laneBits))\(x86Bits(width))"
    let operands = [
        (value: operand, type: x86Vector("i\(laneBits)")),
        (value: x86ShiftCount(amount), type: x86Block("i\(laneBits)")),
    ]
    return x86Builtin(name, operands, returning: type)
}

func x86Shift(
    _ instruction: String,
    laneBits: Int,
    width: Int,
    returning type: String
) -> String {
    x86RegisterShift(
        instruction,
        "a",
        by: "bits",
        laneBits: laneBits,
        width: width,
        returning: type
    )
}

func x86ShiftSame(
    _ instruction: String,
    _ operand: String,
    by amount: String,
    into result: String,
    laneBits: Int,
    width: Int,
    returning type: String
) -> String {
    let immediate = x86ImmediateShift(
        instruction,
        operand,
        by: amount,
        laneBits: laneBits,
        width: width,
        returning: type
    )
    let register = x86RegisterShift(
        instruction,
        operand,
        by: amount,
        laneBits: laneBits,
        width: width,
        returning: type
    )
    return """
        \(type) \(result);
        if (__builtin_constant_p(\(amount))) {
          \(result) = \(immediate);
        } else {
          \(result) = \(register);
        }
        """
}

func x86ShiftedLeft(for element: Element) -> String {
    guard element.bits == 8 else {
        let shifted = x86Shift(
            "psll",
            laneBits: element.bits,
            width: element.width,
            returning: element.cVector
        )
        return vectorResult(shifted, for: element)
    }
    let unsigned = element.cUnsignedVector
    let shifted = x86Shift("psll", laneBits: 16, width: element.width, returning: unsigned)
    let mask = splat("mask", as: unsigned, lanes: element.laneCount)
    return """
        const \(unsigned) shifted = \(shifted);
        const uint8_t mask = (uint8_t)(0xFFu << (bits & 31));
        \(vectorResult(fromUnsignedBits("shifted & \(mask)", of: element), for: element))
        """
}

func x86ShiftedRight(level: X86Level, for element: Element) -> String {
    let unsigned = element.cUnsignedVector
    switch (element.category, element.bits) {
    case (.unsignedInteger, 8):
        let shifted = x86Shift("psrl", laneBits: 16, width: element.width, returning: unsigned)
        let mask = splat("mask", as: unsigned, lanes: element.laneCount)
        return """
            const \(unsigned) shifted = \(shifted);
            const uint8_t mask = (uint8_t)(0xFF >> (bits & 31));
            \(vectorResult("shifted & \(mask)", for: element))
            """
    case (.signedInteger, 8):
        let shifted = x86Shift("psrl", laneBits: 16, width: element.width, returning: unsigned)
        let mask = splat("mask", as: unsigned, lanes: element.laneCount)
        let signs = splat("sign", as: unsigned, lanes: element.laneCount)
        return """
            const \(unsigned) shifted = \(shifted);
            const uint8_t mask = (uint8_t)(0xFF >> (bits & 31));
            const \(unsigned) masked = shifted & \(mask);
            const uint8_t sign = (uint8_t)(0x80 >> (bits & 31));
            const \(unsigned) signs = \(signs);
            \(vectorResult("(\(element.cVector))((masked ^ signs) - signs)", for: element))
            """
    case (.signedInteger, 64) where level < .avx3:
        let vector = element.cVector
        let right = x86ShiftSame(
            "psrl",
            "a",
            by: "bits",
            into: "right",
            laneBits: 64,
            width: element.width,
            returning: vector
        )
        let sign: String
        if level >= .sse4 {
            sign = "const \(vector) sign = (\(vector))(\(compoundLiteral(vector, ["0"])) > a);"
        } else {
            let i32 = x86Vector("i32")
            sign = """
                const \(i32) signs = (\(i32))a >> 31;
                const \(vector) sign = (\(vector))__builtin_shufflevector(
                  signs, signs, 1, 1, 3, 3);
                """
        }
        let shifted = x86ShiftSame(
            "psll",
            "sign",
            by: "(int)(64u - (unsigned)bits)",
            into: "shifted",
            laneBits: 64,
            width: element.width,
            returning: vector
        )
        return """
            \(right)
            \(sign)
            \(shifted)
            \(vectorResult("right | shifted", for: element))
            """
    default:
        let instruction = element.category == .unsignedInteger ? "psrl" : "psra"
        let shifted = x86Shift(
            instruction,
            laneBits: element.bits,
            width: element.width,
            returning: element.cVector
        )
        return vectorResult(shifted, for: element)
    }
}

func x86Extremum(
    _ name: String,
    _ first: String,
    _ second: String,
    for element: Element
) -> String {
    let suffix = element.bits == 32 ? "ps" : "pd"
    let rounding = element.width == 64 ? ", \(x86CurrentRounding)" : ""
    return
        "__builtin_ia32_\(name)\(suffix)\(x86UnsuffixedBits(element.width))(\(first), \(second)\(rounding))"
}

func x86IsNaN(for element: Element) -> String {
    "__builtin_ia32_cmp\(element.bits == 32 ? "ps" : "pd")(a, a, 3)"
}

func x86Avx3IsNaN(for element: Element) -> String {
    let float = x86Vector(element.cSuffix)
    let bitsType = x86MaskType(lanes: element.laneCount)
    let classes = x86Builtin(
        "fpclassp\(element.bits == 32 ? "s" : "d")\(x86Bits(element.width))_mask",
        [
            (value: "a", type: float),
            (value: "0x81", type: "int"),
            (value: "-1", type: bitsType),
        ],
        returning: bitsType
    )
    let letter = x86LaneLetter(bits: element.bits)
    return x86Builtin(
        "cvtmask2\(letter)\(x86Bits(element.width))",
        [(value: classes, type: bitsType)],
        returning: element.cMask
    )
}

func x86CombiningFunctionName(_ reduction: Reduction, _ element: Element) -> String {
    "cvectorization_ops_x86_\(snakeCased(reduction.combiningOp))_\(element.cSuffix)"
}

func x86CombiningFunction(
    _ reduction: Reduction,
    level: X86Level,
    for element: Element
) -> String {
    guard !x86UsesMinimumPosition(reduction, level: level, for: element) else { return "" }
    let function = cFunction(
        returns: element.cRawVector,
        name: x86CombiningFunctionName(reduction, element),
        parameters: ["\(element.cRawVector) a", "\(element.cRawVector) b"],
        body: "return \(cFunctionName(reduction.combiningOp, element))(a, b);",
        specifiers: "CVECTORIZATION_OPS_FUNCTION"
    )
    return function.trimmingCharacters(in: .newlines)
}

func x86CombiningHelpers(_ reduction: Reduction) -> TargetBodies<Element> {
    TargetBodies(
        avx3: { element in x86CombiningFunction(reduction, level: .avx3, for: element) },
        avx2: { element in x86CombiningFunction(reduction, level: .avx2, for: element) },
        sse4: { element in x86CombiningFunction(reduction, level: .sse4, for: element) },
        sse2: { element in x86CombiningFunction(reduction, level: .sse2, for: element) }
    )
}

func x86Reverse(
    _ source: String,
    into result: String,
    lanes group: Int,
    level: X86Level,
    for element: Element
) -> String {
    let vector = element.cVector
    let declaration = "const \(vector) \(result)"
    let indices = (0..<element.laneCount).map { $0 ^ (group - 1) }
    guard element.bits == 16 else {
        return
            "\(declaration) = __builtin_shufflevector(\(source), \(source), \(laneIndices(indices)));"
    }
    if level >= .ssse3 {
        let bytes = indices.map { String(format: "0x%04X", ((2 * $0 + 1) << 8) | (2 * $0)) }
        let table = compoundLiteral(x86Vector("i16"), bytes)
        return "\(declaration) = \(x86TableLookup(source, table, for: element));"
    }
    var lines: [String] = []
    var shuffled = source
    if group == 8 {
        let i32 = x86Vector("i32")
        let dwords = prefixed(result, "dwords")
        let reversed = "__builtin_shufflevector((\(i32))\(source), (\(i32))\(source), 3, 2, 1, 0)"
        lines.append("const \(i32) \(dwords) = \(reversed);")
        shuffled = "(\(vector))\(dwords)"
    }
    let within = group == 4 ? 4 : 2
    let lower = prefixed(result, "lower")
    let lowerIndices = (0..<8).map { $0 < 4 ? $0 ^ (within - 1) : $0 }
    let upperIndices = (0..<8).map { $0 < 4 ? $0 : $0 ^ (within - 1) }
    lines.append(
        "const \(vector) \(lower) = __builtin_shufflevector(\(shuffled), \(shuffled), \(laneIndices(lowerIndices)));"
    )
    lines.append(
        "\(declaration) = __builtin_shufflevector(\(lower), \(lower), \(laneIndices(upperIndices)));"
    )
    return lines.joined(separator: "\n")
}

func x86CombinedExtremum(_ reduction: Reduction, for element: Element) -> String {
    guard element.category == .unsignedInteger, element.bits == 16 || element.bits == 64 else {
        fatalError("There is no combined x86 extremum of \(element.swiftType)")
    }
    let isMinimum = reduction == .minimum
    if element.bits == 16 {
        let subtracting = "__builtin_elementwise_sub_sat"
        let saturated = isMinimum ? "a - \(subtracting)(a, b)" : "a + \(subtracting)(b, a)"
        return vectorResult(saturated, for: element)
    }
    let (yes, no) = isMinimum ? ("b", "a") : ("a", "b")
    return """
        \(x86UnsignedGreater("a", "b", for: element))
        \(vectorResult(bitSelect("mask", yes, no, of: element), for: element))
        """
}

func x86ComparedExtremum(_ reduction: Reduction, for element: Element) -> String? {
    let isMinimum = reduction == .minimum
    let i64 = x86Vector("i64")
    let greater = x86GreaterThanName(bits: element.bits)
    let (first, second) = ("(\(i64))a", "(\(i64))b")
    switch (element.category, element.bits) {
    case (.signedInteger, 8), (.signedInteger, 32):
        let (yes, no) = isMinimum ? (first, second) : (second, first)
        let selected = "\(x86IfThenElseName)(\(greater)(\(second), \(first)), \(yes), \(no))"
        return vectorResult(selected, for: element)
    case (.unsignedInteger, 32):
        let (yes, no) = isMinimum ? (second, first) : (first, second)
        let sign = splat("0x80000000", as: element.cVector, lanes: element.laneCount)
        return """
            const \(i64) sign = (\(i64))\(sign);
            const \(i64) greater = \(greater)(\(first) ^ sign, \(second) ^ sign);
            \(vectorResult("\(x86IfThenElseName)(greater, \(yes), \(no))", for: element))
            """
    default:
        return nil
    }
}

func x86MinMax(_ reduction: Reduction, level: X86Level, for element: Element) -> String? {
    let isMinimum = reduction == .minimum
    let (name, symbol) = isMinimum ? ("min", "<") : ("max", ">")
    if element.category == .float {
        return vectorResult(x86Extremum(name, "a", "b", for: element), for: element)
    }
    guard level < .avx3 else { return nil }
    if isSignedInteger64(element) {
        let chosen = isMinimum ? (first: "a", second: "b") : (first: "b", second: "a")
        return x86Int64Extremum(chosen, native: level >= .sse4, for: element)
    }
    guard level < .avx2 else { return nil }
    let hasInstruction = element.bits == (element.category == .signedInteger ? 16 : 8)
    guard !hasInstruction else { return nil }
    guard level < .sse4 else { return elementwiseExtremum(name, comparing: symbol, for: element) }
    if let compared = x86ComparedExtremum(reduction, for: element) { return compared }
    return x86CombinedExtremum(reduction, for: element)
}

func x86RoundedAverage(for element: Element) -> String {
    let name = "\(element.bits == 8 ? "pavgb" : "pavgw")\(x86Bits(element.width))"
    let average = x86Builtin(name, ["a", "b"], as: "i\(element.bits)", returning: element.cVector)
    return vectorResult(average, for: element)
}

func portableMagnitude(for element: Element) -> String {
    vectorResult("__builtin_elementwise_abs(a)", for: element)
}

func x86Magnitude(level: X86Level, for element: Element) -> String? {
    guard element.category == .signedInteger, element.bits >= 32 else { return nil }
    let zero = compoundLiteral(element.cVector, ["0"])
    let negated = "const \(element.cVector) negated = \(arithmetic("-", zero, "a", for: element));"
    switch (element.bits, level) {
    case (32, .sse2):
        let i64 = x86Vector("i64")
        let selected = "\(x86IfThenElseName)(sign, (\(i64))negated, (\(i64))a)"
        return """
            const \(i64) sign = (\(i64))(a >> 31);
            \(negated)
            \(vectorResult(selected, for: element))
            """
    case (64, .sse2), (64, .ssse3):
        let i32 = x86Vector("i32")
        return """
            \(negated)
            const \(i32) signs = (\(i32))a >> 31;
            const \(element.cVector) sign = (\(element.cVector))__builtin_shufflevector(
              signs, signs, 1, 1, 3, 3);
            \(vectorResult(bitSelect("sign", "negated", "a", of: element), for: element))
            """
    default:
        return portableMagnitude(for: element)
    }
}

func x86MinimumPosition(_ reduction: Reduction, for element: Element) -> String {
    func minimumPosition(_ operand: String) -> String {
        x86Builtin("phminposuw128", [operand], as: "i16", returning: element.cVector)
    }
    guard reduction == .maximum else { return "return (\(minimumPosition("a")))[0];" }
    return """
        const \(element.cVector) maximum = \(repeatingVector("0xFFFF", of: element));
        return (maximum - \(minimumPosition("(maximum - a)")))[0];
        """
}

func x86UsesMinimumPosition(
    _ reduction: Reduction,
    level: X86Level,
    for element: Element
) -> Bool {
    reduction != .sum && level == .sse4 && element.category == .unsignedInteger
        && element.bits == 16
}

func x86BlockReductionSteps(
    for element: Element
) -> [(shuffled: String, combined: String, blocks: [Int])] {
    switch element.width {
    case 32:
        return [("swappedBlocks", "folded", [1, 0])]
    case 64:
        return [
            ("swappedBlocks", "folded", [1, 0, 3, 2]),
            ("reversedBlocks", "gathered", [3, 2, 1, 0]),
        ]
    default:
        return []
    }
}

func x86Int32Shuffle(
    _ source: String,
    into result: String,
    lanes indices: [Int],
    for element: Element
) -> String {
    let i32 = x86Vector("i32")
    let lanes = indices.flatMap { [2 * $0, 2 * $0 + 1] }
    let shuffle =
        "__builtin_shufflevector((\(i32))\(source), (\(i32))\(source), \(laneIndices(lanes)))"
    return "const \(element.cVector) \(result) = (\(element.cVector))\(shuffle);"
}

func x86LowestLane(of vector: String, for element: Element) -> String {
    let i64 = x86Vector("i64")
    var statements: [String] = []
    var source = "(\(i64))\(vector)"
    if element.width == 64 {
        statements.append("typedef long long half_vector __attribute__((vector_size(32)));")
        statements.append(
            "const half_vector half = __builtin_shufflevector(\(source), \(source), 0, 1, 2, 3);"
        )
        source = "half"
    }
    statements.append(
        "const \(x86Block("i64")) lowest = __builtin_shufflevector(\(source), \(source), 0, 1);"
    )
    statements.append("return (\(element.cType))(((\(x86Block("i\(element.bits)")))lowest)[0]);")
    return statements.joined(separator: "\n")
}

func x86Reduction(_ reduction: Reduction, level: X86Level, for element: Element) -> String {
    if x86UsesMinimumPosition(reduction, level: level, for: element) {
        return x86MinimumPosition(reduction, for: element)
    }
    let names: [(reversed: String, reduced: String)]
    switch element.blockLaneCount {
    case 2: names = [("reversed", "combined")]
    case 4: names = [("reversed", "pairs"), ("swapped", "combined")]
    default: names = [("reversed", "quads"), ("flipped", "pairs"), ("swapped", "combined")]
    }
    let vector = element.cVector
    let raw = element.cRawVector
    let combining = x86CombiningFunctionName(reduction, element)
    let isWideSum =
        reduction == .sum && element.category != .float && element.bits >= 32
        && element.width >= 32
    let throughInt32 = isWideSum && element.bits == 64
    var statements: [String] = []
    var reduced = "a"
    for step in x86BlockReductionSteps(for: element) {
        let lanes = (0..<element.laneCount).map {
            step.blocks[$0 / element.blockLaneCount] * element.blockLaneCount
                + $0 % element.blockLaneCount
        }
        if throughInt32 && element.width == 64 {
            statements.append(
                x86Int32Shuffle(reduced, into: step.shuffled, lanes: lanes, for: element)
            )
        } else {
            statements.append(
                "const \(vector) \(step.shuffled) = __builtin_shufflevector(\(reduced), \(reduced), \(laneIndices(lanes)));"
            )
        }
        let combined = "\(combining)((\(raw))\(reduced), (\(raw))\(step.shuffled))"
        statements.append("const \(vector) \(step.combined) = (\(vector))\(combined);")
        reduced = step.combined
    }
    for (step, name) in names.enumerated() {
        let group = element.blockLaneCount >> step
        if throughInt32 {
            let lanes = (0..<element.laneCount).map { $0 ^ (group - 1) }
            statements.append(
                x86Int32Shuffle(reduced, into: name.reversed, lanes: lanes, for: element)
            )
        } else {
            statements.append(
                x86Reverse(reduced, into: name.reversed, lanes: group, level: level, for: element)
            )
        }
        let combined = "\(combining)((\(raw))\(reduced), (\(raw))\(name.reversed))"
        statements.append("const \(vector) \(name.reduced) = (\(vector))\(combined);")
        reduced = name.reduced
    }
    statements.append(
        isWideSum ? x86LowestLane(of: reduced, for: element) : "return \(reduced)[0];"
    )
    return statements.joined(separator: "\n")
}

func portableReverse(for element: Element) -> String {
    let indices = (0..<element.laneCount).reversed().map(String.init)
    return vectorResult(
        "__builtin_shufflevector(a, a, \(indices.joined(separator: ", ")))",
        for: element
    )
}

func portableTableLookupBytes(for element: Element) -> String {
    let lookups = (0..<16).map { lane in
        "{\n  const uint8_t index = (uint8_t)indices[\(lane)];\n  result[\(lane)] = index < 16 ? a[index] : 0;\n}"
    }
    return """
        \(element.cVector) result;
        \(lookups.joined(separator: "\n"))
        \(vectorResult("result", for: element))
        """
}

func portableLookupSource(for element: Element) -> String {
    element.bits == 16 ? element.cUnsignedLane : element.cType
}

func portableLookup(of lane: String, for element: Element) -> String {
    let lanes = element.laneCount
    guard element.bits == 16 else {
        return """
            \(element.cVector) result;
            for (size_t i = 0; i < \(lanes); ++i) {
              result[i] = \(lane);
            }
            \(vectorResult("result", for: element))
            """
    }
    return """
        uint64_t words[\(lanes / 4)] = {0};
        for (size_t i = 0; i < \(lanes); ++i) {
          words[i / 4] |= (uint64_t)(\(lane)) << (16 * (i % 4));
        }
        \(element.cVector) result;
        __builtin_memcpy(&result, words, sizeof result);
        \(vectorResult("result", for: element))
        """
}

func portableTableLookupLanes(for element: Element) -> String {
    let lanes = element.laneCount
    return """
        \(portableLookupSource(for: element)) source[\(lanes)];
        \(element.cMaskLane) index[\(lanes)];
        __builtin_memcpy(source, &a, sizeof a);
        __builtin_memcpy(index, &indices, sizeof indices);
        \(portableLookup(of: "source[index[i]]", for: element))
        """
}

func portableTwoTablesLookupLanes(for element: Element) -> String {
    let source = portableLookupSource(for: element)
    let lane = element.cMaskLane
    let lanes = element.laneCount
    let masked = "index[i] & (\(lane))\(lanes - 1)"
    let selected = "index[i] < (\(lane))\(lanes) ? first[\(masked)] : second[\(masked)]"
    return """
        \(source) first[\(lanes)];
        \(source) second[\(lanes)];
        \(lane) index[\(lanes)];
        __builtin_memcpy(first, &a, sizeof a);
        __builtin_memcpy(second, &b, sizeof b);
        __builtin_memcpy(index, &indices, sizeof indices);
        \(portableLookup(of: selected, for: element))
        """
}

func x86ReversedBytes(for element: Element) -> String? {
    guard element.bits == 8 else { return nil }
    let i16 = x86Vector("i16")
    let i32 = x86Vector("i32")
    let right = x86ImmediateShift("psrl", "a", by: "8", laneBits: 16, returning: i16)
    let left = x86ImmediateShift("psll", "a", by: "8", laneBits: 16, returning: i16)
    let lower = laneIndices([3, 2, 1, 0, 4, 5, 6, 7])
    let upper = laneIndices([0, 1, 2, 3, 7, 6, 5, 4])
    let words = "__builtin_shufflevector((\(i32))reversed, (\(i32))reversed, 2, 3, 0, 1)"
    return """
        const \(i16) right = \(right);
        const \(i16) left = \(left);
        const \(i16) rotated = right | left;
        const \(i16) lower = __builtin_shufflevector(rotated, rotated, \(lower));
        const \(i16) reversed = __builtin_shufflevector(lower, lower, \(upper));
        \(vectorResult("(\(element.cVector))\(words)", for: element))
        """
}

func x86TableLookup(_ bytes: String, _ indices: String, for element: Element) -> String {
    let name = "pshufb\(x86Bits(element.width))"
    return x86Builtin(name, [bytes, indices], as: "i8", returning: element.cVector)
}

func x86Sse2TableLookupBytes(for element: Element) -> String {
    """
    \(x86EmulatedTableLookupBytes("a", "indices", into: "looked"))
    \(vectorResult("(\(element.cVector))looked", for: element))
    """
}

func x86EmulatedLaneLookup(
    _ table: String,
    _ indices: String,
    into result: String,
    for element: Element
) -> String {
    let type = x86Vector("i64")
    let lanes = element.blockLaneCount
    let indexLane = element.bits == 16 ? "uint16_t" : "int32_t"
    let mask = element.bits == 16 ? "7u" : "3"
    let lookup = """
        \(element.cType) resultLanes[\(lanes)] __attribute__((aligned(16)));
        \(element.cType) tableLanes[\(lanes)] __attribute__((aligned(16)));
        \(indexLane) indexLanes[\(lanes)] __attribute__((aligned(16)));
        const \(type) tableVector = (\(type))\(table);
        const \(type) indexVector = (\(type))\(indices);
        __builtin_memcpy(tableLanes, &tableVector, 16);
        __builtin_memcpy(indexLanes, &indexVector, 16);
        for (int i = 0; i < \(lanes); i++) {
          resultLanes[i] = tableLanes[indexLanes[i] & \(mask)];
        }
        __builtin_memcpy(&\(result), resultLanes, 16);
        """
    return "\(type) \(result);\n{\n\(indented(lookup))\n}"
}

func x86LaneByteIndices(for element: Element) -> String {
    let bytes = element.bits / 8
    let int8 = x86Vector("i8")
    let broadcast = x86ByteTable(
        "broadcast",
        lookupBroadcastBytes(lane: bytes, width: element.width)
    )
    let offsets = x86ByteTable("offsets", lookupByteOffsets(lane: bytes, width: element.width))
    let lanes = x86Builtin(
        "pshufb\(x86Bits(element.width))",
        ["indices", "broadcast"],
        as: "i8",
        returning: int8
    )
    let shifted = "(\(x86Vector("i16")))laneIndices << \(bytes.trailingZeroBitCount)"
    return """
        \(broadcast)
        \(offsets)
        const \(int8) laneIndices = \(lanes);
        const \(int8) byteIndices = (\(int8))(\(shifted)) + offsets;
        """
}

func x86Avx2WordIndices(for element: Element) -> String {
    let int64 = x86Vector("i64")
    let float = x86Vector("f32")
    let indices = "(\(float))indices"
    let duplicated = "__builtin_shufflevector(\(indices), \(indices), 0, 0, 2, 2, 4, 4, 6, 6)"
    let carry = splat("4294967296ll", as: int64, lanes: element.laneCount)
    return """
        const \(int64) duplicated = (\(int64))\(duplicated);
        const \(int64) wordIndices = duplicated + duplicated + \(carry);
        """
}

func x86Int64LaneLookup(level: X86Level, for element: Element) -> String {
    let int64 = x86Vector("i64")
    let asInt32 = "(\(x86Vector("i32")))"
    let selected =
        level >= .sse4
        ? x86Builtin("pblendvb128", ["swapped", "table", "same"], as: "i8", returning: int64)
        : "(same & table) | (~same & swapped)"
    let iota = compoundLiteral(int64, ["0", "1"])
    return """
        const \(int64) table = (\(int64))a;
        const \(int64) same = ((\(int64))indices ^ \(iota)) - \(splat("1", as: int64, lanes: 2));
        const \(int64) swapped = (\(int64))__builtin_shufflevector(\(asInt32)table, \(asInt32)table, 2, 3, 0, 1);
        \(vectorResult(selected, for: element))
        """
}

func x86Permute(_ table: String, _ indices: String, for element: Element) -> String {
    x86Builtin(
        "permvar\(x86PermuteName(of: element))\(x86Bits(element.width))",
        [
            (value: table, type: x86Vector(x86LaneSuffix(of: element))),
            (value: indices, type: x86Vector("i\(element.bits)")),
        ],
        returning: element.cVector
    )
}

func x86Avx2ByteLaneLookup(for element: Element) -> String {
    let int16 = x86Vector("i16")
    let lowerTable = x86Avx2Concat(.lowerLower, hi: "a", lo: "a", for: element)
    let upperTable = x86Avx2Concat(.upperUpper, hi: "a", lo: "a", for: element)
    return """
        const \(int16) selector = (\(int16))indices << 3;
        const \(element.cVector) lower = \(x86TableLookup(lowerTable, "indices", for: element));
        const \(element.cVector) upper = \(x86TableLookup(upperTable, "indices", for: element));
        \(vectorResult(x86Selecting("selector", "upper", "lower", for: element), for: element))
        """
}

func x86Avx3ByteLaneLookup(for element: Element) -> String {
    let int16 = x86Vector("i16")
    let int32 = x86Vector("i32")
    let maskType = x86MaskType(lanes: element.laneCount)
    func table(_ name: String, _ control: Int) -> String {
        let shuffled = x86Builtin(
            "shuf_i32x4",
            [
                (value: "a", type: int32), (value: "a", type: int32),
                (value: x86Immediate(control), type: "int"),
            ],
            returning: int32
        )
        return "const \(int32) \(name) = \(shuffled);"
    }
    let tables = [
        table("tableA", 0x00), table("tableB", 0x55), table("tableC", 0xAA), table("tableD", 0xFF),
    ]
    func lookup(_ table: String) -> String {
        x86TableLookup(table, "indices", for: element)
    }
    return """
        const \(int16) shiftedBy3 = (\(int16))indices << 3;
        const \(int16) shiftedBy2 = (\(int16))indices << 2;
        const \(maskType) selectsUpperHalves = \(x86Avx3MaskBits("shiftedBy3", for: element));
        const \(maskType) selectsUpperQuarters = \(x86Avx3MaskBits("shiftedBy2", for: element));
        \(tables.joined(separator: "\n"))
        const \(element.cVector) lookedA = \(lookup("tableA"));
        const \(element.cVector) lookedC = \(lookup("tableC"));
        const \(element.cVector) lookedAB = \(x86Avx3Select("selectsUpperHalves", lookup("tableB"), "lookedA", for: element));
        const \(element.cVector) lookedCD = \(x86Avx3Select("selectsUpperHalves", lookup("tableD"), "lookedC", for: element));
        \(vectorResult(x86Avx3Select("selectsUpperQuarters", "lookedCD", "lookedAB", for: element), for: element))
        """
}

func x86TableLookupLanes(level: X86Level, for element: Element) -> String {
    switch (level, element.bits) {
    case (.sse2, 8):
        return x86Sse2TableLookupBytes(for: element)
    case (.sse2, 16), (.sse2, 32):
        return """
            \(x86EmulatedLaneLookup("a", "indices", into: "looked", for: element))
            \(vectorResult("(\(element.cVector))looked", for: element))
            """
    case (.sse2, _), (.ssse3, 64), (.sse4, 64):
        return x86Int64LaneLookup(level: level, for: element)
    case (.ssse3, 8), (.sse4, 8):
        return vectorResult(x86TableLookup("a", "indices", for: element), for: element)
    case (.ssse3, _), (.sse4, _):
        return """
            \(x86LaneByteIndices(for: element))
            \(vectorResult(x86TableLookup("a", "byteIndices", for: element), for: element))
            """
    case (.avx2, 8):
        return x86Avx2ByteLaneLookup(for: element)
    case (.avx2, 16):
        let byte = unsignedElement(bits: 8)
        let raw = byte.cRawVector
        let function = cFunctionName("tableLookupLanes", byte)
        return """
            \(x86LaneByteIndices(for: element))
            \(vectorResult("\(function)((\(raw))rawA, (\(raw))byteIndices)", for: element))
            """
    case (.avx2, 32):
        return vectorResult(x86Permute("a", "indices", for: element), for: element)
    case (.avx2, _):
        let words = x86Vector("i32")
        let lookup = x86Builtin(
            "permvarsi256",
            [(value: "a", type: words), (value: "wordIndices", type: words)],
            returning: element.cVector
        )
        return """
            \(x86Avx2WordIndices(for: element))
            \(vectorResult(lookup, for: element))
            """
    case (.avx3, 8):
        return x86Avx3ByteLaneLookup(for: element)
    case (.avx3, _), (.avx3dl, _):
        return vectorResult(x86Permute("a", "indices", for: element), for: element)
    }
}

func x86Sse2TableLookupBytesOrZero(for element: Element) -> String {
    let int8 = x86Vector("i8")
    return """
        const \(int8) signedIndices = (\(int8))indices;
        \(x86TableLookupBytesOr0("a", "signedIndices", into: "zeroed", level: .sse2))
        \(vectorResult("(\(element.cVector))zeroed", for: element))
        """
}

func tableLookupBytesTargets(zeroing: Bool) -> TargetBodies<Element> {
    func lookup(_ element: Element) -> String {
        vectorResult(x86TableLookup("a", "indices", for: element), for: element)
    }
    return TargetBodies(
        neon: { element in
            vectorResult(neonTableLookup("a", "indices", for: element), for: element)
        },
        sve2_128: zeroing ? { element in sveTableLookupLanes(for: element) } : nil,
        avx3: lookup,
        avx2: lookup,
        ssse3: lookup,
        sse2: { element in
            zeroing
                ? x86Sse2TableLookupBytesOrZero(for: element)
                : x86Sse2TableLookupBytes(for: element)
        }
    )
}

func x86TwoTablesLookupLanes(level: X86Level, for element: Element) -> String {
    let vector = element.cVector
    let lookup = cFunctionName("tableLookupLanes", element)
    let indexRaw = laneIndexElement(of: element).cRawVector
    func lookups(_ indices: String = "rawIndices", upperFirst: Bool = false) -> String {
        let lower = "const \(vector) lower = (\(vector))\(lookup)(rawA, \(indices));"
        let upper = "const \(vector) upper = (\(vector))\(lookup)(rawB, \(indices));"
        return upperFirst ? "\(upper)\n\(lower)" : "\(lower)\n\(upper)"
    }
    func compared(with limit: Int) -> String {
        let type = x86Vector("i\(element.bits)")
        let limits = splat("\(limit)", as: type, lanes: element.laneCount)
        return "const \(type) selector = (\(type))((\(type))indices > \(limits));"
    }
    func routed(through route: Element, indices: String) -> String {
        let function = cFunctionName("twoTablesLookupLanes", route)
        let raw = route.cRawVector
        let call = "\(function)((\(raw))rawA, (\(raw))rawB, (\(raw))\(indices))"
        return vectorResult(call, for: element)
    }
    func shifted(by bits: Int, lanes laneBits: Int) -> String {
        let type = x86Vector("i\(laneBits)")
        return "const \(type) selector = (\(type))indices << \(bits);"
    }
    switch (level, element.bits) {
    case (.sse2, 8), (.ssse3, 8):
        return """
            \(compared(with: 15))
            \(lookups())
            \(vectorResult(x86BitSelect("selector", "upper", "lower", for: element), for: element))
            """
    case (.sse4, 8):
        return """
            \(shifted(by: 3, lanes: 16))
            \(lookups())
            \(vectorResult(x86Selecting("selector", "upper", "lower", for: element), for: element))
            """
    case (.sse2, 16), (.sse2, 32):
        return """
            \(compared(with: element.bits == 16 ? 7 : 3))
            \(lookups())
            \(vectorResult(x86BitSelect("selector", "upper", "lower", for: element), for: element))
            """
    case (.ssse3, 16), (.ssse3, 32), (.sse4, 16), (.sse4, 32):
        return """
            \(x86LaneByteIndices(for: element))
            \(routed(through: unsignedElement(bits: 8), indices: "byteIndices"))
            """
    case (.sse2, _), (.ssse3, _), (.sse4, _):
        let int64 = x86Vector("i64")
        let int32 = x86Vector("i32")
        let ones = splat("1", as: int64, lanes: 2)
        let modulo = "const \(int64) moduloIndices = (\(int64))indices & \(ones);"
        let selector: String
        let selected: String
        if level == .sse4 {
            selector = "const \(int64) selector = (\(int64))indices << 62;"
            selected = x86Builtin(
                "blendvpd",
                ["lower", "upper", "selector"],
                as: "f64",
                returning: x86Vector("f64")
            )
        } else {
            let indices = "(\(int32))indices"
            let duplicated = "__builtin_shufflevector(\(indices), \(indices), 0, 0, 2, 2)"
            selector = """
                const \(int32) duplicated = \(duplicated);
                const \(int64) selector = (\(int64))(duplicated > \(splat("1", as: int32, lanes: 4)));
                """
            selected = x86BitSelect("selector", "upper", "lower", for: element)
        }
        return """
            \(modulo)
            \(selector)
            \(lookups("(\(indexRaw))moduloIndices"))
            \(vectorResult(selected, for: element))
            """
    case (.avx2, 8):
        return """
            \(shifted(by: 2, lanes: 16))
            \(lookups())
            \(vectorResult(x86Selecting("selector", "upper", "lower", for: element), for: element))
            """
    case (.avx2, 16):
        return """
            \(x86LaneByteIndices(for: element))
            \(routed(through: unsignedElement(bits: 8), indices: "byteIndices"))
            """
    case (.avx2, 32):
        let blended = x86Builtin(
            "blendvps256",
            ["lower", "upper", "selector"],
            as: "f32",
            returning: x86Vector("f32")
        )
        return """
            \(shifted(by: 28, lanes: 32))
            \(lookups())
            \(vectorResult(blended, for: element))
            """
    case (.avx2, _):
        return """
            \(x86Avx2WordIndices(for: element))
            \(routed(through: unsignedElement(bits: 32), indices: "wordIndices"))
            """
    case (.avx3, 8):
        let int16 = x86Vector("i16")
        let maskType = x86MaskType(lanes: element.laneCount)
        return """
            const \(int16) shifted = (\(int16))indices << 1;
            const \(maskType) selectsUpper = \(x86Avx3MaskBits("shifted", for: element));
            \(lookups(upperFirst: true))
            \(vectorResult(x86Avx3Select("selectsUpper", "upper", "lower", for: element), for: element))
            """
    case (.avx3, _), (.avx3dl, _):
        return vectorResult(x86TwoTableLookup("a", "indices", "b", for: element), for: element)
    }
}

func slideShuffle(_ direction: SlideDirection, by amount: Int, for element: Element) -> String {
    let lanes = element.laneCount
    let zero = compoundLiteral(element.cVector, ["0"])
    switch direction {
    case .up:
        let indices = laneIndices(lanes - amount..<2 * lanes - amount)
        return "__builtin_shufflevector(\(zero), a, \(indices))"
    case .down:
        let indices = laneIndices(amount..<lanes + amount)
        return "__builtin_shufflevector(a, \(zero), \(indices))"
    }
}

func constantLanesSwitch(
    _ cases: [(amount: Int, body: String)],
    when condition: String? = nil
) -> String {
    let lines = cases.map { "case \($0.amount): \($0.body)" }
    let guarded = (["__builtin_constant_p(lanes)"] + (condition.map { [$0] } ?? []))
        .joined(separator: " && ")
    return """
        if (\(guarded)) {
          switch (lanes) {
        \(indented(indented(lines.joined(separator: "\n"))))
          }
        }
        """
}

func slideConstants(
    _ direction: SlideDirection,
    byteShifted: Bool = false,
    custom: (Int) -> String? = { _ in nil },
    evenOnly: Bool = false,
    for element: Element
) -> String {
    let cases = (1..<element.laneCount).filter { !evenOnly || $0 % 2 == 0 }.map { amount in
        if let body = custom(amount) {
            return (amount: amount, body: "{\n\(indented(body))\n}")
        }
        let shuffle =
            byteShifted
            ? x86SlideBytes(direction, by: amount, for: element)
            : slideShuffle(direction, by: amount, for: element)
        return (amount: amount, body: vectorResult(shuffle, for: element))
    }
    return constantLanesSwitch([(amount: 0, body: vectorResult("a", for: element))] + cases)
}

let neonSlideTableName = "cvectorization_ops_neon_slide_table"

func neonSlideIndices(_ direction: SlideDirection, for element: Element) -> String {
    let bytes = "cvectorization_ops_vector_u8"
    let offset = direction == .up ? "-" : "+"
    return """
        \(bytes) indices;
        __builtin_memcpy(&indices, \(neonSlideTableName)() + 16 \(offset) lanes * sizeof(\(element.cType)), sizeof indices);
        """
}

func x86SlideIndices(_ direction: SlideDirection, for element: Element) -> String {
    switch direction {
    case .up:
        let bytes = "cvectorization_ops_vector_u8"
        let first = splat("first", as: bytes, lanes: element.width)
        return """
            const uint8_t first = (uint8_t)(0 - lanes * sizeof(\(element.cType)));
            const \(bytes) indices = \(first) + \(iota(as: bytes, lanes: element.width));
            """
    case .down:
        let unsigned = "cvectorization_ops_vector_u8"
        let bytes = x86Vector("i8")
        let first = splat("first", as: unsigned, lanes: element.width)
        let limit = splat("\(element.width - 1)", as: bytes, lanes: element.width)
        return """
            const uint8_t first = (uint8_t)(lanes * sizeof(\(element.cType)));
            const \(bytes) offsets = (\(bytes))(\(first) + \(iota(as: unsigned, lanes: element.width)));
            const \(bytes) indices = offsets | (offsets > \(limit));
            """
    }
}

func x86ByteSlide(_ direction: SlideDirection, for element: Element) -> String {
    let i8 = x86Vector("i8")
    let blockBytes = 16
    let bytes = element.width
    let low = laneIndices(0..<blockBytes, 0..<blockBytes)
    let high = laneIndices(blockBytes..<bytes, blockBytes..<bytes)
    let pshufb = "pshufb\(x86Bits(element.width))"
    let blend = "pblendvb\(x86Bits(element.width))"
    func lookup(_ part: String) -> String {
        let block = "\(part.lowercased())Block"
        let shuffled = x86Builtin(pshufb, [block, "indices"], as: "i8", returning: i8)
        return "const \(i8) from\(part) = \(shuffled);"
    }
    let blended = x86Builtin(
        blend,
        ["fromLow", "fromHigh", "selected"],
        as: "i8",
        returning: element.cVector
    )
    let selected = x86ImmediateShift(
        "psll",
        "indices",
        by: "3",
        laneBits: 16,
        width: element.width,
        returning: i8
    )
    let lowBlock = "const \(i8) lowBlock = __builtin_shufflevector(bytes, bytes, \(low));"
    let highBlock = "const \(i8) highBlock = __builtin_shufflevector(bytes, bytes, \(high));"
    let statements =
        switch direction {
        case .up:
            [
                x86SlideIndices(.up, for: element),
                "const \(i8) bytes = (\(i8))a;",
                lowBlock,
                highBlock,
                lookup("Low"),
                lookup("High"),
            ]
        case .down:
            [
                x86SlideIndices(.down, for: element),
                "const \(i8) bytes = (\(i8))a;",
                lowBlock,
                lookup("Low"),
                highBlock,
                lookup("High"),
            ]
        }
    return """
        \(statements.joined(separator: "\n"))
        const \(i8) selected = \(selected);
        \(vectorResult(blended, for: element))
        """
}

func x86WordSlide(_ direction: SlideDirection, for element: Element) -> String {
    let words = "cvectorization_ops_vector_u32"
    let i32 = x86Vector("i32")
    let lanes = element.width / 4
    let amount = "lanes * \(element.bits / 32)"
    let first = direction == .up ? "(uint32_t)(0 - \(amount))" : "(uint32_t)(\(amount))"
    let limits = (0..<lanes).map { element.bits == 64 ? 6 + $0 % 2 : lanes - 1 }
    let permuted = x86Builtin("permvarsi256", ["a", "masked"], as: "i32", returning: i32)
    return """
        const uint32_t first = \(first);
        const \(words) indices = \(splat("first", as: words, lanes: lanes)) + \(iota(as: words, lanes: lanes));
        const \(words) masked = indices & \(compoundLiteral(words, limits.map(String.init)));
        const \(i32) gathered = \(permuted);
        \(vectorResult("(\(element.cVector))(gathered & (indices == masked))", for: element))
        """
}

func x86WideSlide(_ direction: SlideDirection, for element: Element) -> String {
    element.bits < 32
        ? x86ByteSlide(direction, for: element) : x86WordSlide(direction, for: element)
}

func x86TwoTableLookup(
    _ first: String,
    _ indices: String,
    _ second: String,
    for element: Element
) -> String {
    guard let suffix = [8: "qi", 16: "hi", 32: "d", 64: "q"][element.bits] else {
        fatalError("There is no x86 two table lookup of \(element.bits)-bit lanes")
    }
    let name = element.category == .float ? "p\(element.bits == 32 ? "s" : "d")" : suffix
    let table = x86Vector(x86LaneSuffix(of: element))
    return x86Builtin(
        "vpermi2var\(name)\(x86Bits(element.width))",
        [
            (value: first, type: table),
            (value: indices, type: x86Vector("i\(element.bits)")),
            (value: second, type: table),
        ],
        returning: element.cVector
    )
}

func x86TwoTableSlide(
    _ direction: SlideDirection,
    by amount: String = "lanes",
    for element: Element
) -> String {
    guard direction == .up || element.bits == 8 else {
        fatalError("There is no x86 two table slide down of \(element.bits)-bit lanes")
    }
    let lanes = element.laneCount
    let unsigned = element.cUnsignedVector
    let table = x86Vector(x86LaneSuffix(of: element))
    let isMasked = element.bits > 8
    let lookup = x86TwoTableLookup(
        "a",
        isMasked ? "masked" : "indices",
        compoundLiteral(table, ["0"]),
        for: element
    )
    let first = direction == .up ? "0 - \(amount)" : amount
    var statements = [
        "const \(element.cUnsignedLane) first = (\(element.cUnsignedLane))(\(first));",
        "const \(unsigned) indices = \(splat("first", as: unsigned, lanes: lanes)) + \(iota(as: unsigned, lanes: lanes));",
    ]
    if isMasked {
        let limit = splat("\(2 * lanes - 1)", as: unsigned, lanes: lanes)
        statements.append("const \(unsigned) masked = indices & \(limit);")
    }
    statements.append(vectorResult(lookup, for: element))
    return statements.joined(separator: "\n")
}

func x86PermuteName(of element: Element, viewingAsIntegers: Bool = false) -> String {
    guard element.category != .float || viewingAsIntegers else {
        return element.bits == 32 ? "sf" : "df"
    }
    guard let suffix = [8: "qi", 16: "hi", 32: "si", 64: "di"][element.bits] else {
        fatalError("There is no x86 permute of \(element.bits)-bit lanes")
    }
    return suffix
}

func x86PermuteSlideDown(for element: Element) -> String {
    let lanes = element.laneCount
    let unsigned = element.cUnsignedVector
    let table = x86Vector(x86LaneSuffix(of: element))
    let permuted = x86Builtin(
        "permvar\(x86PermuteName(of: element))\(x86Bits(element.width))",
        [(value: "a", type: table), (value: "masked", type: x86Vector("i\(element.bits)"))],
        returning: table
    )
    let limit = splat("\(lanes - 1)", as: unsigned, lanes: lanes)
    let valid = "(\(unsigned))(indices == masked)"
    return """
        const \(element.cUnsignedLane) first = (\(element.cUnsignedLane))lanes;
        const \(unsigned) indices = \(splat("first", as: unsigned, lanes: lanes)) + \(iota(as: unsigned, lanes: lanes));
        const \(unsigned) masked = indices & \(limit);
        const \(table) gathered = \(permuted);
        \(vectorResult("(\(unsigned))gathered & \(valid)", for: element))
        """
}

func x86Avx3Slide(
    _ direction: SlideDirection,
    level: X86Level,
    for element: Element
) -> String {
    let slid =
        switch (direction, element.bits) {
        case (.up, 8) where level < .avx3dl: x86Avx3ByteSlideUp(for: element)
        case (.down, 8) where level < .avx3dl: x86Avx3ByteSlideDown(for: element)
        case (_, 8), (.up, _): x86TwoTableSlide(direction, for: element)
        case (.down, _): x86PermuteSlideDown(for: element)
        }
    let slide1 = slide1Body(direction, level: level, for: element)
    let slidesBytes = element.bits == 8 && level < .avx3dl
    let constants = slideConstants(
        direction,
        custom: { amount in
            switch amount {
            case 1: slide1
            case element.laneCount / 2 where direction == .up && isFloat32(element):
                x86Avx3ConcatLowerLower(for: element)
            case _ where slidesBytes && amount % 2 == 1:
                x86Avx3ByteSlideBlocks(direction, by: amount, for: element)
            default: nil
            }
        },
        evenOnly: direction == .down && element.bits == 16,
        for: element
    )
    return "\(constants)\n\(slid)"
}

func x86Avx3ConcatLowerLower(for element: Element) -> String {
    let f32 = x86Vector("f32")
    let shuffled = x86Builtin(
        "shuf_f32x4",
        [
            (value: compoundLiteral(f32, ["0"]), type: f32),
            (value: "a", type: f32),
            (value: "0x44", type: "int"),
        ],
        returning: element.cVector
    )
    return vectorResult(shuffled, for: element)
}

func x86Avx3ByteSlideBlocks(
    _ direction: SlideDirection,
    by amount: Int,
    for element: Element
) -> String {
    let i8 = x86Vector("i8")
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    let zero = compoundLiteral(i64, ["0"])
    let width = x86Bits(element.width)
    func quads(_ count: Int) -> String {
        switch (direction, count) {
        case (_, 0):
            return "whole"
        case (.up, 4):
            return x86Builtin(
                "shuf_i32x4",
                [
                    (value: zero, type: i32), (value: "whole", type: i32),
                    (value: "0x44", type: "int"),
                ],
                returning: i64
            )
        case (.down, 4):
            return "__builtin_shufflevector(whole, \(zero), 4, 5, 6, 7, 8, 9, 10, 11)"
        case (.up, _):
            return x86Builtin(
                "alignq\(width)",
                [
                    (value: "whole", type: i64),
                    (value: zero, type: i64),
                    (value: "\(8 - count)", type: "int"),
                ],
                returning: i64
            )
        case (.down, _):
            return x86Builtin(
                "alignq\(width)",
                [
                    (value: zero, type: i64),
                    (value: "whole", type: i64),
                    (value: "\(count)", type: "int"),
                ],
                returning: i64
            )
        }
    }
    let blocks = (amount >> 4) << 1
    let (nearer, farther) = (quads(blocks), blocks <= 4 ? quads(blocks + 2) : zero)
    let (high, low, bytes) =
        switch direction {
        case .up: (nearer, farther, 16 - amount % 16)
        case .down: (farther, nearer, amount % 16)
        }
    let shifted = x86Builtin(
        "palignr\(width)",
        [(value: "high", type: i8), (value: "low", type: i8), (value: "\(bytes)", type: "int")],
        returning: element.cVector
    )
    let operands = [(name: "high", value: high), (name: "low", value: low)]
    let statements = (direction == .up ? operands : operands.reversed()).map {
        "const \(i64) \($0.name) = \($0.value);"
    }
    return """
        const \(i64) whole = (\(i64))a;
        \(statements.joined(separator: "\n"))
        \(vectorResult(shifted, for: element))
        """
}

func x86Avx3SlideFillingCase(
    _ direction: SlideDirection,
    laneBits: Int,
    by amount: Int,
    for element: Element
) -> String {
    let lanes = element.width * 8 / laneBits
    let letter = x86LaneLetter(bits: laneBits)
    let vector = x86Vector("i\(laneBits)")
    let maskType = x86MaskType(lanes: lanes)
    let allLanes = (UInt64(1) << UInt64(lanes)) - 1
    let (kept, shift) =
        switch direction {
        case .up: (allLanes & ~((UInt64(1) << UInt64(amount)) - 1), lanes - amount)
        case .down: ((UInt64(1) << UInt64(lanes - amount)) - 1, amount)
        }
    let aligned = x86Builtin(
        "align\(letter)\(x86Bits(element.width))",
        [
            (value: rawName("a"), type: vector),
            (value: rawName("a"), type: vector),
            (value: "\(shift)", type: "int"),
        ],
        returning: vector
    )
    let selected = x86Builtin(
        "select\(letter)_\(x86Bits(element.width))",
        [
            (value: "0x\(String(kept, radix: 16))", type: maskType),
            (value: aligned, type: vector),
            (value: rawName("fill"), type: vector),
        ],
        returning: element.cVector
    )
    return vectorResult(selected, for: element)
}

func x86Avx3SlideFillingConstants(
    _ direction: SlideDirection,
    for element: Element
) -> String {
    func wideCase(_ amount: Int, laneBits: Int) -> String {
        x86Avx3SlideFillingCase(direction, laneBits: laneBits, by: amount, for: element)
    }
    func wordCase(_ words: Int) -> String {
        switch words {
        case 0: return vectorResult(rawName("a"), for: element)
        case _ where words % 2 == 1: return wideCase(words, laneBits: 32)
        default: return wideCase(words / 2, laneBits: 64)
        }
    }
    switch element.bits {
    case 64:
        let cases = (0..<element.laneCount).map { amount in
            (
                amount: amount,
                body: amount == 0
                    ? vectorResult(rawName("a"), for: element) : wideCase(amount, laneBits: 64)
            )
        }
        return constantLanesSwitch(cases)
    case 32:
        return constantLanesSwitch(
            (0..<element.laneCount).map { (amount: $0, body: wordCase($0)) }
        )
    default:
        let lanesPerWord = 32 / element.bits
        let cases = (0..<16).map { words in
            (amount: words * lanesPerWord, body: wordCase(words))
        }
        return constantLanesSwitch(cases, when: "(lanes & \(lanesPerWord - 1)) == 0")
    }
}

func x86Avx3SlideFilling(
    _ direction: SlideDirection,
    level: X86Level,
    for element: Element
) -> String {
    let lanes = element.laneCount
    let maskType = x86MaskType(lanes: lanes)
    let count = direction == .up ? "lanes" : "(\(lanes) - lanes)"
    let selected = "(\(maskType))\(x86FirstLanesBits(lanes: lanes, count: count))"
    let permutes =
        switch element.bits {
        case 8: level == .avx3dl
        case 16: direction == .down
        default: true
        }
    guard permutes else {
        let slid = "\(slideLanesName(direction, for: element))(\(rawName("a")), lanes)"
        let (yes, no) = direction == .up ? (rawName("fill"), slid) : (slid, rawName("fill"))
        return """
            \(x86Avx3SlideFillingConstants(direction, for: element))
            const \(maskType) selected = \(selected);
            \(vectorResult(x86Avx3Select("selected", yes, no, for: element), for: element))
            """
    }
    let integers = x86Vector("i\(element.bits)")
    let unsigned = element.cUnsignedVector
    let first = direction == .up ? "0 - lanes" : "lanes"
    let permuted = x86Builtin(
        "permvar\(x86PermuteName(of: element, viewingAsIntegers: true))\(x86Bits(element.width))",
        [(value: rawName("a"), type: integers), (value: "indices", type: integers)],
        returning: integers
    )
    let (yes, no) = direction == .up ? (rawName("fill"), permuted) : (permuted, rawName("fill"))
    return """
        \(x86Avx3SlideFillingConstants(direction, for: element))
        const \(maskType) selected = \(selected);
        const \(element.cUnsignedLane) first = (\(element.cUnsignedLane))(\(first));
        const \(unsigned) indices = \(splat("first", as: unsigned, lanes: lanes)) + \(iota(as: unsigned, lanes: lanes));
        \(vectorResult(x86Avx3Select("selected", yes, no, for: element), for: element))
        """
}

func x86Avx3ByteSlideUp(for element: Element) -> String {
    let indexVector = "cvectorization_ops_vector_u8"
    let blockVector = "block_vector"
    let i8 = x86Vector("i8")
    let i64 = x86Vector("i64")
    let blockLanes = element.width / 8
    let even = laneIndices(0..<16, 0..<16, 32..<48, 32..<48)
    let odd = laneIndices(48..<64, 16..<32, 16..<32, 48..<64)
    let pshufb = "pshufb\(x86Bits(element.width))"
    let fromEven = x86Builtin(pshufb, ["evenBlocks", "indices"], as: "i8", returning: i8)
    let fromOdd = x86Builtin(pshufb, ["oddBlocks", "indices"], as: "i8", returning: i8)
    let selected = x86ImmediateShift(
        "psll",
        "indices",
        by: "3",
        laneBits: 16,
        width: element.width,
        returning: i8
    )
    let bits = x86Builtin(
        "cvtb2mask\(x86Bits(element.width))",
        ["selected"],
        as: "i8",
        returning: x86MaskType(lanes: element.laneCount)
    )
    let blended = x86Builtin(
        "selectb_\(x86Bits(element.width))",
        [
            (value: bits, type: x86MaskType(lanes: element.laneCount)),
            (value: "fromOdd", type: i8),
            (value: "fromEven", type: i8),
        ],
        returning: i8
    )
    let lookup = x86Builtin(
        "vpermi2varq\(x86Bits(element.width))",
        ["blended", "blockIndices", compoundLiteral(i64, ["0"])],
        as: "i64",
        returning: element.cVector
    )
    return """
        typedef uint64_t \(blockVector) __attribute__((vector_size(\(element.width))));
        const uint8_t first = (uint8_t)(0 - (lanes & 15));
        const \(indexVector) indices = \(splat("first", as: indexVector, lanes: element.width)) + \(iota(as: indexVector, lanes: element.width));
        const uint64_t blockFirst = (uint64_t)(0 - ((lanes >> 4) << 1));
        const \(blockVector) blockIndices = \(splat("blockFirst", as: blockVector, lanes: blockLanes)) + \(iota(as: blockVector, lanes: blockLanes));
        const \(i8) bytes = (\(i8))a;
        const \(i8) evenBlocks = __builtin_shufflevector(bytes, bytes, \(even));
        const \(i8) oddBlocks = __builtin_shufflevector(bytes, bytes, \(odd));
        const \(i8) fromEven = \(fromEven);
        const \(i8) fromOdd = \(fromOdd);
        const \(i8) selected = \(selected);
        const \(i8) blended = \(blended);
        \(vectorResult(lookup, for: element))
        """
}

func x86Avx3ByteSlideDown(for element: Element) -> String {
    let indexVector = "cvectorization_ops_vector_u8"
    let blockVector = "block_vector"
    let i8 = x86Vector("i8")
    let i64 = x86Vector("i64")
    let blockLanes = element.width / 8
    let even = laneIndices(0..<16, 32..<48, 32..<48, 0..<16)
    let odd = laneIndices(16..<32, 16..<32, 48..<64, 48..<64)
    let pshufb = "pshufb\(x86Bits(element.width))"
    let maskType = x86MaskType(lanes: element.laneCount)
    let selected = x86ImmediateShift(
        "psll",
        "indices",
        by: "3",
        laneBits: 16,
        width: element.width,
        returning: i8
    )
    let oddSelect = x86Builtin(
        "cvtb2mask\(x86Bits(element.width))",
        [selected],
        as: "i8",
        returning: maskType
    )
    let fromEven = x86Builtin(
        "selectb_\(x86Bits(element.width))",
        [
            (value: "0x0000FFFFFFFFFFFFULL", type: maskType),
            (
                value: x86Builtin(pshufb, ["evenBlocks", "indices"], as: "i8", returning: i8),
                type: i8
            ),
            (value: compoundLiteral(i8, ["0"]), type: i8),
        ],
        returning: i8
    )
    let blended = x86Builtin(
        "selectb_\(x86Bits(element.width))",
        [
            (value: "oddSelect", type: maskType),
            (
                value: x86Builtin(pshufb, ["oddBlocks", "indices"], as: "i8", returning: i8),
                type: i8
            ),
            (value: "fromEven", type: i8),
        ],
        returning: i8
    )
    let lookup = x86Builtin(
        "vpermi2varq\(x86Bits(element.width))",
        ["blended", "blockIndices", compoundLiteral(i64, ["0"])],
        as: "i64",
        returning: element.cVector
    )
    return """
        typedef uint64_t \(blockVector) __attribute__((vector_size(\(element.width))));
        const uint8_t first = (uint8_t)(lanes & 15);
        const \(indexVector) indices = \(splat("first", as: indexVector, lanes: element.width)) + \(iota(as: indexVector, lanes: element.width));
        const \(i8) bytes = (\(i8))a;
        const \(maskType) oddSelect = \(oddSelect);
        const \(i8) oddBlocks = __builtin_shufflevector(bytes, bytes, \(odd));
        const \(i8) evenBlocks = __builtin_shufflevector(bytes, bytes, \(even));
        const \(i8) fromEven = \(fromEven);
        const \(i8) blended = \(blended);
        const uint64_t blockFirst = (uint64_t)((lanes >> 4) << 1);
        const \(blockVector) blockIndices = \(splat("blockFirst", as: blockVector, lanes: blockLanes)) + \(iota(as: blockVector, lanes: blockLanes));
        \(vectorResult(lookup, for: element))
        """
}

func x86ByteShift(_ direction: SlideDirection, _ operand: String, by bytes: Int) -> String {
    let name = direction == .up ? "pslldqi128" : "psrldqi128"
    return "__builtin_ia32_\(name)_byteshift(\(operand), \(bytes))"
}

func x86SlideBytes(_ direction: SlideDirection, by lanes: Int, for element: Element) -> String {
    let shifted = x86ByteShift(direction, "(\(x86Vector("i64")))a", by: lanes * element.bits / 8)
    return "(\(element.cVector))\(shifted)"
}

func x86Slide(_ direction: SlideDirection, for element: Element) -> String {
    let vector = x86Vector("i64")
    let selected = compoundLiteral(x86Vector("i32"), Array(repeating: "selected", count: 4))
    let (own, ownShift, other, otherShift) =
        switch direction {
        case .up: ("high", "psll", "low", "psrl")
        case .down: ("low", "psrl", "high", "psll")
        }
    let shiftedOwn = "shifted\(uppercasedFirst(own))"
    let shiftedOther = "shifted\(uppercasedFirst(other))"
    let ownShifted = x86ShiftSame(
        ownShift,
        own,
        by: "shift",
        into: shiftedOwn,
        laneBits: 64,
        width: element.width,
        returning: vector
    )
    let otherShifted = x86ShiftSame(
        otherShift,
        other,
        by: "64 - shift",
        into: shiftedOther,
        laneBits: 64,
        width: element.width,
        returning: vector
    )
    return """
        const int selected = -(int)(lanes >= \(element.laneCount / 2));
        const \(vector) mask = (\(vector))\(selected);
        const \(vector) whole = (\(vector))a;
        const \(vector) moved = \(x86ByteShift(direction, "whole", by: 8));
        const \(vector) \(own) = (mask & moved) | (~mask & whole);
        const \(vector) \(other) = \(x86ByteShift(direction, own, by: 8));
        const int shift = (int)((lanes * \(element.bits)) & 63);
        \(ownShifted)
        \(otherShifted)
        \(vectorResult("(\(element.cVector))(\(shiftedOwn) | \(shiftedOther))", for: element))
        """
}

func slideTargets(_ direction: SlideDirection) -> TargetBodies<Element> {
    TargetBodies(
        neon: { element in
            """
            \(slideConstants(direction, for: element))
            \(neonSlideIndices(direction, for: element))
            \(vectorResult(neonTableLookup("a", "indices", for: element), for: element))
            """
        },
        sve2_128: direction == .up ? { element in sveSlideUp(filling: false, for: element) } : nil,
        avx3dl: { element in x86Avx3Slide(direction, level: .avx3dl, for: element) },
        avx3: { element in x86Avx3Slide(direction, level: .avx3, for: element) },
        avx2: { element in
            let custom = x86WideSlideAmount(direction, for: element)
            return """
                \(slideConstants(direction, custom: custom, for: element))
                \(x86WideSlide(direction, for: element))
                """
        },
        ssse3: { element in
            """
            \(slideConstants(direction, for: element))
            \(x86SlideIndices(direction, for: element))
            \(vectorResult(x86TableLookup("a", "indices", for: element), for: element))
            """
        },
        sse2: { element in
            """
            \(slideConstants(direction, for: element))
            \(x86Slide(direction, for: element))
            """
        }
    )
}

func portableSlideOperands(
    _ direction: SlideDirection,
    by lanes: String,
    for element: Element
) -> (destination: String, source: String, size: String) {
    let lane = element.cType
    let size = "(\(element.laneCount) - \(lanes)) * sizeof(\(lane))"
    switch direction {
    case .up: return ("(\(lane)*)&result + \(lanes)", "&source", size)
    case .down: return ("&result", "(const \(lane)*)&source + \(lanes)", size)
    }
}

func portableSlideCopy(
    _ direction: SlideDirection,
    by lanes: String,
    for element: Element
) -> String {
    let (destination, source, size) = portableSlideOperands(direction, by: lanes, for: element)
    return "__builtin_memcpy(\(destination), \(source), \(size));"
}

func portableSlide(_ direction: SlideDirection, for element: Element) -> String {
    let lanes = element.laneCount
    let (destination, source, size) = portableSlideOperands(direction, by: "clamped", for: element)
    return """
        \(element.cVector) result;
        const \(element.cVector) source = a;
        const size_t clamped = lanes < \(lanes) ? lanes : \(lanes);
        void *const destination = \(destination);
        const void *const origin = \(source);
        const size_t size = \(size);
        __builtin_memset(&result, 0, sizeof result);
        __builtin_memcpy(destination, origin, size);
        \(vectorResult("result", for: element))
        """
}

func bytewiseSlide1(_ direction: SlideDirection, for element: Element) -> String {
    let bytes = "cvectorization_ops_vector_u8"
    let zero = compoundLiteral(bytes, ["0"])
    let width = element.width
    let amount = element.bits / 8
    switch direction {
    case .up:
        let indices = laneIndices(width - amount..<2 * width - amount)
        return "(\(element.cVector))__builtin_shufflevector(\(zero), (\(bytes))a, \(indices))"
    case .down:
        let indices = laneIndices(amount..<width + amount)
        return "(\(element.cVector))__builtin_shufflevector((\(bytes))a, \(zero), \(indices))"
    }
}

func portableSlide1(_ direction: SlideDirection, for element: Element) -> String {
    if element.bits == 32 && element.width == 16 && element.category != .float {
        return vectorResult(bytewiseSlide1(direction, for: element), for: element)
    }
    return """
        \(element.cVector) result;
        const \(element.cVector) source = a;
        result = (\(element.cVector)){0};
        \(portableSlideCopy(direction, by: "1", for: element))
        \(vectorResult("result", for: element))
        """
}

func shuffledSlide1(_ direction: SlideDirection, for element: Element) -> String {
    vectorResult(slideShuffle(direction, by: 1, for: element), for: element)
}

func slide1Targets(_ direction: SlideDirection) -> TargetBodies<Element> {
    func avx3(_ level: X86Level) -> (Element) -> String? {
        { element in
            direction == .down && element.bits == 16
                ? nil : x86Avx3Slide1(direction, level: level, for: element)
        }
    }
    return TargetBodies(
        neon: { element in shuffledSlide1(direction, for: element) },
        avx3dl: avx3(.avx3dl),
        avx3: avx3(.avx3),
        avx2: { element in x86WideSlideBytes(direction, by: element.bits / 8, for: element) },
        sse2: { element in
            direction == .up && isFloat32(element)
                ? x86Slide1Up(for: element) : shuffledSlide1(direction, for: element)
        }
    )
}

func slide1Body(_ direction: SlideDirection, level: X86Level, for element: Element) -> String {
    let targets = slide1Targets(direction)
    let specific = level.inherited.lazy.compactMap { targets.body(at: $0)?(element) }.first
    return specific ?? portableSlide1(direction, for: element)
}

func neonSlideFillingTableName(_ direction: SlideDirection) -> String {
    "cvectorization_ops_neon_slide_\(direction.rawValue)_or_table"
}

func neonSlideFillingTable(_ direction: SlideDirection) -> [Int] {
    (0...16).flatMap { shift in
        (0..<16).map { byte in
            switch direction {
            case .up: return byte < shift ? byte : 16 + byte - shift
            case .down: return byte + shift < 16 ? 16 + byte + shift : byte
            }
        }
    }
}

func neonSlideFillingIndices(_ direction: SlideDirection, for element: Element) -> String {
    let bytes = "cvectorization_ops_vector_u8"
    return """
        \(bytes) indices;
        __builtin_memcpy(&indices, \(neonSlideFillingTableName(direction))() + 16 * lanes * sizeof(\(element.cType)), sizeof indices);
        """
}

func slideLanesName(_ direction: SlideDirection, for element: Element) -> String {
    cFunctionName("slide\(uppercasedFirst(direction.rawValue))Lanes", element)
}

func slideFilling(
    _ direction: SlideDirection,
    sliding slide: String,
    for element: Element
) -> String {
    let raw = element.cRawVector
    let slid = "\(slide)((\(raw))a, lanes)"
    let filled = "(\(raw))fill"
    let (count, yes, no) =
        switch direction {
        case .up: ("lanes", filled, slid)
        case .down: ("\(element.laneCount) - lanes", slid, filled)
        }
    let mask = "\(cFunctionName("firstLanes", element))(\(count))"
    return "return \(cFunctionName("selecting", element))(\(mask), \(yes), \(no));"
}

func neonSlideFilling(_ direction: SlideDirection, for element: Element) -> String {
    let slide = slideLanesName(direction, for: element)
    let lookup = neonTwoTablesLookup("fill", "a", "indices", for: element)
    return """
        if (__builtin_constant_p(lanes)) {
        \(indented(slideFilling(direction, sliding: slide, for: element)))
        }
        \(neonSlideFillingIndices(direction, for: element))
        \(vectorResult(lookup, for: element))
        """
}

func x86SlideLanesName(_ direction: SlideDirection, for element: Element) -> String {
    "cvectorization_ops_x86_slide_\(direction.rawValue)_lanes_\(element.cSuffix)"
}

func x86SlideLanes(_ direction: SlideDirection, for element: Element) -> String {
    let function = cFunction(
        returns: element.cRawVector,
        name: x86SlideLanesName(direction, for: element),
        parameters: ["\(element.cRawVector) rawA", "size_t lanes"],
        body: """
            const \(element.cVector) a = (\(element.cVector))rawA;
            \(slideConstants(direction, byteShifted: true, for: element))
            return \(slideLanesName(direction, for: element))(rawA, lanes);
            """
    )
    return function.trimmingCharacters(in: .newlines)
}

func slideFillingTargets(_ direction: SlideDirection) -> TargetBodies<Element> {
    TargetBodies(
        neon: { element in neonSlideFilling(direction, for: element) },
        sve2_128: direction == .up ? { element in sveSlideUp(filling: true, for: element) } : nil,
        avx3dl: { element in x86Avx3SlideFilling(direction, level: .avx3dl, for: element) },
        avx3: { element in x86Avx3SlideFilling(direction, level: .avx3, for: element) },
        sse4: { element in
            slideFilling(direction, sliding: slideLanesName(direction, for: element), for: element)
        },
        sse2: { element in
            slideFilling(
                direction,
                sliding: x86SlideLanesName(direction, for: element),
                for: element
            )
        }
    )
}

func slide1FillingLane(_ direction: SlideDirection, for element: Element) -> Int {
    direction == .up ? 0 : element.laneCount - 1
}

func slideFilledLane(_ vector: String, _ lane: Int, for element: Element) -> String {
    """
    \(element.cVector) result = \(vector);
    result[\(lane)] = fill;
    \(vectorResult("result", for: element))
    """
}

func slide1Filling(_ direction: SlideDirection, for element: Element) -> String {
    if element.category == .float && element.laneCount == 2 {
        let filled = repeatingVector("fill", of: element)
        let shuffle =
            direction == .up
            ? "__builtin_shufflevector(\(filled), a, 0, 2)"
            : "__builtin_shufflevector(a, \(filled), 1, 2)"
        return vectorResult(shuffle, for: element)
    }
    let slide = cFunctionName("slide1\(uppercasedFirst(direction.rawValue))", element)
    let slid = "(\(element.cVector))\(slide)((\(element.cRawVector))a)"
    return slideFilledLane(slid, slide1FillingLane(direction, for: element), for: element)
}

func x86Slide1Filling(
    _ direction: SlideDirection,
    level: X86Level,
    for element: Element
) -> String {
    let lane = slide1FillingLane(direction, for: element)
    let shifted = x86SlideBytes(direction, by: 1, for: element)
    guard level < .sse4 else { return slideFilledLane(shifted, lane, for: element) }
    let raw = element.cRawVector
    if element.bits == 8 || isInteger32(element) || isFloat32(element) {
        let mask = "(\(raw))\(laneMask(lane, for: element))"
        let filled = "\(cFunctionName("repeating", element))(fill)"
        let selected = cFunctionName("selecting", element)
        return "return \(selected)(\(mask), \(filled), (\(raw))\(shifted));"
    }
    guard isInteger64(element) else { return slideFilledLane(shifted, lane, for: element) }
    let (f64, i64) = (x86Vector("f64"), x86Vector("i64"))
    let asFloat = x86AsFloatName(bits: 64)
    let operands = lane == 0 ? "inserted, whole, 0, 3" : "whole, inserted, 0, 2"
    return """
        const \(f64) inserted = \(asFloat)((\(i64))\(cFunctionName("repeating", element))(fill));
        const \(f64) whole = \(asFloat)((\(i64))\(shifted));
        \(vectorResult("__builtin_shufflevector(\(operands))", for: element))
        """
}

func x86WideSlide1Filling(_ direction: SlideDirection, for element: Element) -> String? {
    guard element.bits > 8 else { return nil }
    let raw = element.cRawVector
    let lane = slide1FillingLane(direction, for: element)
    let slide = cFunctionName("slide1\(uppercasedFirst(direction.rawValue))", element)
    let mask = "(\(element.cRawMask))\(laneMask(lane, for: element))"
    let filled = "\(cFunctionName("repeating", element))(fill)"
    let selected = cFunctionName("selecting", element)
    return """
        const \(raw) slid = \(slide)((\(raw))a);
        return \(selected)(\(mask), \(filled), slid);
        """
}

func slide1FillingTargets(_ direction: SlideDirection) -> TargetBodies<Element> {
    TargetBodies(
        avx3: { element in x86Avx3Slide1(direction, filling: true, for: element) },
        avx2: { element in x86WideSlide1Filling(direction, for: element) },
        sse4: { element in x86Slide1Filling(direction, level: .sse4, for: element) },
        sse2: { element in x86Slide1Filling(direction, level: .sse2, for: element) }
    )
}

func isInteger32(_ element: Element) -> Bool {
    element.bits == 32 && element.category != .float
}

func isInteger64(_ element: Element) -> Bool {
    element.bits == 64 && element.category != .float
}

func isFloat32(_ element: Element) -> Bool {
    element.bits == 32 && element.category == .float
}

func isSignedInteger64(_ element: Element) -> Bool {
    element.bits == 64 && element.category == .signedInteger
}

func isUnsigned64(_ element: Element) -> Bool {
    element.bits == 64 && element.category == .unsignedInteger
}

func maskedBitwise(_ symbol: String, for element: Element) -> String {
    let operation = unsignedBits("(a \(symbol) b)", of: element)
    let selected = fromUnsignedBits("\(operation) & (\(element.cUnsignedVector))mask", of: element)
    return vectorResult(selected, for: element)
}

func commutedMaskedBitwise(_ symbol: String, for element: Element) -> String {
    let operation = unsignedBits("(a \(symbol) b)", of: element)
    let selected = fromUnsignedBits("(\(element.cUnsignedVector))mask & \(operation)", of: element)
    return vectorResult(selected, for: element)
}

func maskedBitwiseOtherwise(_ symbol: String, for element: Element) -> String {
    let selecting = cFunctionName("selecting", element)
    let raw = element.cRawVector
    let operands = ["(\(element.cRawMask))mask", "(\(raw))(a \(symbol) b)", "(\(raw))otherwise"]
    return "return \(selecting)(\(operands.joined(separator: ", ")));"
}

func x86Avx3MaskedBitwise(
    _ symbol: String,
    otherwise: String? = nil,
    for element: Element
) -> String {
    let vector = x86Vector(x86LaneSuffix(of: element))
    let operation = "(\(vector))a \(symbol) (\(vector))b"
    let selected = x86Avx3Selecting(
        "mask",
        "(\(vector))(\(operation))",
        otherwise ?? compoundLiteral(vector, ["0"]),
        for: element
    )
    return vectorResult(selected, for: element)
}

func x86Avx3AndXor(for element: Element) -> String {
    let i64 = x86Vector("i64")
    let ternary = x86Builtin(
        "pternlogq\(x86Bits(element.width))_mask",
        [
            (value: "a", type: i64),
            (value: "b", type: i64),
            (value: "c", type: i64),
            (value: "0x60", type: "int"),
            (value: "-1", type: x86MaskType(lanes: element.width / 8)),
        ],
        returning: element.cVector
    )
    return vectorResult(ternary, for: element)
}

func maskedBitwiseTargets(
    _ symbol: String,
    neon: ((Element) -> String?)? = nil
) -> TargetBodies<Element> {
    TargetBodies(
        neon: neon,
        avx3: { element in x86Avx3MaskedBitwise(symbol, for: element) }
    )
}

func maskedBitwiseOtherwiseTargets(_ symbol: String, operation: String) -> TargetBodies<Element> {
    TargetBodies(
        sve2_128: { element in sveMaskedBitwiseOtherwise(operation, for: element) },
        avx3: { element in
            x86Avx3MaskedBitwise(symbol, otherwise: rawName("otherwise"), for: element)
        }
    )
}

let multiplyAddedBits = 52

func multiplyAddingLow52Bits(for element: Element) -> String {
    let raw = element.cRawVector
    let multiplying = cFunctionName("multiplying", element)
    let product = "(\(element.cVector))\(multiplying)((\(raw))a, (\(raw))b)"
    let mask = (UInt64(1) << UInt64(multiplyAddedBits)) - 1
    let kept = splat("0x\(String(mask, radix: 16))", as: element.cVector, lanes: element.laneCount)
    return vectorResult("(\(product) & \(kept)) + c", for: element)
}

func multiplyAddingHighResult(low: String, for element: Element) -> String {
    let shifted = "(\(low) >> \(multiplyAddedBits)) | (high << \(element.bits - multiplyAddedBits))"
    return vectorResult("(\(shifted)) + c", for: element)
}

func multiplyAddingHigh52BitsHalves(flippingSigns: Bool, for element: Element) -> String {
    let vector = element.cVector
    let raw = element.cRawVector
    func multiplying(_ first: String, _ second: String) -> String {
        let arguments = [first, second].map { "(\(raw))\($0)" }.joined(separator: ", ")
        return "(\(vector))\(cFunctionName("multiplying", element))(\(arguments))"
    }
    func flipped(_ operand: String) -> String {
        let signBit = "0x\(String(UInt64(1) << UInt64(element.bits - 1), radix: 16))"
        let sign = "\(cFunctionName("repeating", element))(\(signBit))"
        return "\(cFunctionName("bitwiseXor", element))((\(raw))\(operand), \(sign))"
    }
    let carried =
        flippingSigns
        ? "\(x86GreaterThanName(bits: element.bits))(\(flipped("p0")), \(flipped("low")))"
        : "\(cFunctionName("greaterThan", element))((\(raw))p0, (\(raw))low)"
    let ones = "\(cFunctionName("repeating", element))(1)"
    let selected = [carried, ones, "\(cFunctionName("zero", element))()"]
    let carry = "\(cFunctionName("selecting", element))(\(selected.joined(separator: ", ")))"
    let halfBits = element.bits / 2
    let halfMask = splat("0xffffffff", as: vector, lanes: element.laneCount)
    return """
        const \(vector) mask = \(halfMask);
        const \(vector) a0 = a & mask;
        const \(vector) b0 = b & mask;
        const \(vector) a1 = a >> \(halfBits);
        const \(vector) b1 = b >> \(halfBits);
        const \(vector) p0 = \(multiplying("a0", "b0"));
        const \(vector) p1Add = \(multiplying("a0", "b1"));
        const \(vector) p1 = \(multiplying("a1", "b0")) + p1Add;
        const \(vector) low = p0 + ((p1 & mask) << \(halfBits));
        const \(vector) carry = (\(vector))\(carry);
        const \(vector) high = \(multiplying("a1", "b1")) + (p1 >> \(halfBits)) + carry;
        \(multiplyAddingHighResult(low: "low", for: element))
        """
}

func multiplyAddingHigh52BitsWhole(for element: Element) -> String {
    let vector = element.cVector
    let lane = element.cUnsignedLane
    let halfBits = element.bits / 2
    let wide = "unsigned __int128"
    return """
        const \(vector) low = a * b;
        \(vector) high;
        for (size_t i = 0; i < \(element.laneCount); ++i) {
        #if defined(__SIZEOF_INT128__)
          high[i] = (\(lane))(((\(wide))a[i] * (\(wide))b[i]) >> \(element.bits));
        #else
          const \(lane) loLo = (a[i] & 0xffffffff) * (b[i] & 0xffffffff);
          const \(lane) hiLo = (a[i] >> \(halfBits)) * (b[i] & 0xffffffff);
          const \(lane) loHi = (a[i] & 0xffffffff) * (b[i] >> \(halfBits));
          const \(lane) hiHi = (a[i] >> \(halfBits)) * (b[i] >> \(halfBits));
          const \(lane) t = (loLo >> \(halfBits)) + (hiLo & 0xffffffff) + loHi;
          high[i] = (hiLo >> \(halfBits)) + (t >> \(halfBits)) + hiHi;
        #endif
        }
        \(multiplyAddingHighResult(low: "low", for: element))
        """
}

func x86MultiplyAdding52Bits(high: Bool, for element: Element) -> String {
    let name = "vpmadd52\(high ? "h" : "l")uq\(x86Bits(element.width))"
    let fused = x86Builtin(name, ["c", "a", "b"], as: "i64", returning: element.cVector)
    return vectorResult(fused, for: element)
}

func x86Multiplying32(for element: Element) -> String {
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    let evens = x86Builtin("pmuludq128", ["a", "b"], as: "i32", returning: i64)
    let odds = x86Builtin("pmuludq128", ["a_x3x1", "b_x3x1"], as: "i32", returning: i64)
    let product = "(\(element.cVector))__builtin_shufflevector(mul_20, mul_31, 0, 4, 1, 5)"
    return """
        const \(i32) a_x3x1 = __builtin_shufflevector((\(i32))a, (\(i32))a, 1, 1, 3, 3);
        const \(i64) mullo_x2x0 = \(evens);
        const \(i32) b_x3x1 = __builtin_shufflevector((\(i32))b, (\(i32))b, 1, 1, 3, 3);
        const \(i64) mullo_x3x1 = \(odds);
        const \(i32) mul_20 = __builtin_shufflevector(
          (\(i32))mullo_x2x0, (\(i32))mullo_x2x0, 0, 2, 0, 2);
        const \(i32) mul_31 = __builtin_shufflevector(
          (\(i32))mullo_x3x1, (\(i32))mullo_x3x1, 0, 2, 0, 2);
        \(vectorResult(product, for: element))
        """
}

func x86Int64Greater(
    _ first: String,
    _ second: String,
    native: Bool = false,
    for element: Element
) -> String {
    let mask = element.cMask
    guard !native else { return "const \(mask) mask = (\(mask))(\(first) > \(second));" }
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    return """
        const \(i32) equal = (\(i32))\(first) == (\(i32))\(second);
        const \(i32) greater = (\(i32))\(first) > (\(i32))\(second);
        const \(i64) difference = (\(i64))\(second) - (\(i64))\(first);
        const \(i64) upper = (\(i64))greater | ((\(i64))equal & difference);
        const \(mask) mask = (\(mask))__builtin_shufflevector(
          (\(i32))upper, (\(i32))upper, 1, 1, 3, 3);
        """
}

func x86SignedGreater(
    _ first: String,
    _ second: String,
    native: Bool,
    for element: Element
) -> String {
    guard element.bits == 64 else {
        let mask = element.cMask
        return "const \(mask) mask = (\(mask))(\(first) > \(second));"
    }
    return x86Int64Greater(first, second, native: native, for: element)
}

func x86UnsignedGreater(
    _ first: String,
    _ second: String,
    native: Bool = false,
    for element: Element
) -> String {
    let signed = x86Vector("i\(element.bits)")
    let signBit = String(UInt64(1) << UInt64(element.bits - 1), radix: 16)
    let i64 = x86Vector("i64")
    return """
        const \(element.cVector) flip = \(repeatingVector("0x\(signBit)", of: element));
        const \(signed) signedFirst = (\(signed))((\(i64))\(first) ^ (\(i64))flip);
        const \(signed) signedSecond = (\(signed))((\(i64))\(second) ^ (\(i64))flip);
        \(x86SignedGreater("signedFirst", "signedSecond", native: native, for: element))
        """
}

func x86Int64Comparison(_ first: String, _ second: String, for element: Element) -> String {
    "\(x86Int64Greater(first, second, for: element))\n\(maskResult("mask", for: element))"
}

func x86UnsignedComparison(
    _ first: String,
    _ second: String,
    native: Bool = false,
    for element: Element
) -> String {
    let greater = x86UnsignedGreater(first, second, native: native, for: element)
    return "\(greater)\n\(maskResult("mask", for: element))"
}

func x86Int64Extremum(
    _ chosen: (first: String, second: String),
    native: Bool = false,
    for element: Element
) -> String {
    """
    \(x86Int64Greater("b", "a", native: native, for: element))
    \(vectorResult(bitSelect("mask", chosen.first, chosen.second, of: element), for: element))
    """
}

func x86Selecting(
    _ mask: String,
    _ yes: String,
    _ no: String,
    for element: Element
) -> String {
    let (name, suffix) =
        element.category == .float
        ? (
            "blendv\(element.bits == 32 ? "ps" : "pd")\(x86UnsuffixedBits(element.width))",
            element.cSuffix
        )
        : ("pblendvb\(x86Bits(element.width))", "i8")
    return x86Builtin(name, [no, yes, mask], as: suffix, returning: element.cVector)
}

func x86Avx3Select(
    _ bits: String,
    _ yes: String,
    _ no: String,
    for element: Element
) -> String {
    let name =
        element.category == .float
        ? "selectp\(element.bits == 32 ? "s" : "d")" : "select\(x86LaneLetter(bits: element.bits))"
    let vector = x86Vector(x86LaneSuffix(of: element))
    return x86Builtin(
        "\(name)_\(x86Bits(element.width))",
        [
            (value: bits, type: x86MaskType(lanes: element.laneCount)),
            (value: yes, type: vector),
            (value: no, type: vector),
        ],
        returning: element.cVector
    )
}

func x86Avx3Selecting(
    _ mask: String,
    _ yes: String,
    _ no: String,
    for element: Element
) -> String {
    x86Avx3Select(x86Avx3MaskBits(mask, for: element), yes, no, for: element)
}

func x86BitSelect(_ mask: String, _ yes: String, _ no: String, for element: Element) -> String {
    guard element.category != .float else { return bitSelect(mask, yes, no, of: element) }
    let i64 = x86Vector("i64")
    let chosen = "(\(i64))\(mask) & (\(i64))\(yes)"
    let rest = "~(\(i64))\(mask) & (\(i64))\(no)"
    return "(\(element.cVector))((\(chosen)) | (\(rest)))"
}

func x86Immediate(_ value: Int) -> String {
    value < 10 ? "\(value)" : "0x\(String(value, radix: 16, uppercase: true))"
}

func x86WideSlideQuads(
    _ direction: SlideDirection,
    by quads: Int,
    for element: Element
) -> String {
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    let f64 = x86Vector("f64")
    let sources = (0..<4).map { ((direction == .up ? $0 - quads : $0 + quads) % 4 + 4) % 4 }
    let permutation = x86Immediate(
        sources.enumerated().reduce(0) { $0 | $1.element << (2 * $1.offset) }
    )
    let (floatBlend, integerBlend) =
        switch direction {
        case .up: (x86Immediate((1 << quads) - 1), x86Immediate((1 << (quads * 2)) - 1))
        case .down:
            (
                x86Immediate((0x0F << (4 - quads)) & 0x0F),
                x86Immediate((0xFF << ((4 - quads) * 2)) & 0xFF)
            )
        }
    let permutationOperand = (value: permutation, type: "int")
    guard element.category != .float else {
        let permuted = x86Builtin(
            "permdf256",
            [(value: "a", type: f64), permutationOperand],
            returning: f64
        )
        let blended = x86Builtin(
            "blendpd256",
            [
                (value: permuted, type: f64),
                (value: compoundLiteral(f64, ["0"]), type: f64),
                (value: floatBlend, type: "int"),
            ],
            returning: element.cVector
        )
        return vectorResult(blended, for: element)
    }
    let permuted = x86Builtin(
        "permdi256",
        [(value: "a", type: i64), permutationOperand],
        returning: i64
    )
    let blended = x86Builtin(
        "pblendd256",
        [
            (value: permuted, type: i32),
            (value: compoundLiteral(i32, ["0"]), type: i32),
            (value: integerBlend, type: "int"),
        ],
        returning: element.cVector
    )
    return vectorResult(blended, for: element)
}

func x86WideSlideBytes(
    _ direction: SlideDirection,
    by bytes: Int,
    for element: Element
) -> String {
    guard bytes != 8 && bytes != 24 else {
        return x86WideSlideQuads(direction, by: bytes / 8, for: element)
    }
    guard bytes < 16 else { return x86WideSlideHalf(direction, by: bytes, for: element) }
    let i8 = x86Vector("i8")
    let i64 = x86Vector("i64")
    guard direction == .up else {
        let shifted = x86Builtin(
            "palignr256",
            [
                (value: "high", type: i8),
                (value: "whole", type: i8),
                (value: "\(bytes)", type: "int"),
            ],
            returning: element.cVector
        )
        return """
            const \(i64) whole = (\(i64))a;
            const \(i64) high = __builtin_shufflevector(whole, (\(i64)){0}, 2, 3, 4, 5);
            \(vectorResult(shifted, for: element))
            """
    }
    let shifted = x86Builtin(
        "palignr256",
        [
            (value: "whole", type: i8),
            (value: "lower", type: i8),
            (value: "\(16 - bytes)", type: "int"),
        ],
        returning: element.cVector
    )
    guard isFloat32(element) else {
        let lower = x86Builtin(
            "permti256",
            [
                (value: compoundLiteral(i64, ["0"]), type: i64),
                (value: "whole", type: i64),
                (value: "0x20", type: "int"),
            ],
            returning: i64
        )
        return """
            const \(i64) whole = (\(i64))a;
            const \(i64) lower = \(lower);
            \(vectorResult(shifted, for: element))
            """
    }
    let f32 = x86Vector("f32")
    let lower = x86Builtin(
        "vperm2f128_ps256",
        [
            (value: compoundLiteral(f32, ["0"]), type: f32),
            (value: "whole", type: f32),
            (value: "0x20", type: "int"),
        ],
        returning: f32
    )
    return """
        const \(f32) whole = (\(f32))a;
        const \(f32) lower = \(lower);
        \(vectorResult(shifted, for: element))
        """
}

func x86WideSlideHalf(
    _ direction: SlideDirection,
    by bytes: Int,
    for element: Element
) -> String {
    let suffix = element.category == .float ? element.cSuffix : "i64"
    let vector = x86Vector(suffix)
    let block = x86Block(suffix)
    let zero = compoundLiteral(block, ["0"])
    let blockLanes = 16 / (element.category == .float ? element.bits / 8 : 8)
    let wholeLanes = 2 * blockLanes
    let shifted = x86ByteShift(
        direction,
        "(\(x86Block("i64")))half",
        by: bytes - 16
    )
    let (half, result) =
        switch direction {
        case .up:
            (
                laneIndices(0..<blockLanes),
                "__builtin_shufflevector(\(zero), shifted, \(laneIndices(0..<wholeLanes)))"
            )
        case .down:
            (
                laneIndices(blockLanes..<wholeLanes),
                "__builtin_shufflevector(shifted, \(zero), \(laneIndices(0..<wholeLanes)))"
            )
        }
    return """
        const \(vector) whole = (\(vector))a;
        const \(block) half = __builtin_shufflevector(whole, whole, \(half));
        const \(block) shifted = (\(block))\(shifted);
        \(vectorResult(result, for: element))
        """
}

func x86WideSlideAmount(_ direction: SlideDirection, for element: Element) -> (Int) -> String? {
    { amount in
        let bytes = amount * element.bits / 8
        let isShorterAsShuffle =
            bytes == 16
            || (direction == .up && (bytes == 31 || (bytes == 24 && !isFloat32(element))))
        return isShorterAsShuffle ? nil : x86WideSlideBytes(direction, by: bytes, for: element)
    }
}

func x86Avx3Slide1(
    _ direction: SlideDirection,
    level: X86Level = .avx3,
    filling: Bool = false,
    for element: Element
) -> String {
    let isTableLookup = element.bits == 16 || (element.bits == 8 && level == .avx3dl)
    guard direction == .down || filling || !isTableLookup else {
        return x86TwoTableSlide(.up, by: "1", for: element)
    }
    let width = x86Bits(element.width)
    let fill = filling ? "set" : "0"
    func aligned(
        _ name: String,
        laneBits: Int,
        by lanes: Int,
        returning type: String
    ) -> String {
        let vector = x86Vector("i\(laneBits)")
        let filler = filling ? fill : compoundLiteral(vector, [fill])
        let (high, low) = direction == .up ? ("a", filler) : (filler, "a")
        return x86Builtin(
            name,
            [
                (value: high, type: vector),
                (value: low, type: vector),
                (value: "\(lanes)", type: "int"),
            ],
            returning: type
        )
    }
    let set =
        filling ? "const \(element.cVector) set = \(repeatingVector("fill", of: element));\n" : ""
    guard element.bits < 32 else {
        let shifted = aligned(
            "\(element.bits == 32 ? "alignd" : "alignq")\(width)",
            laneBits: element.bits,
            by: direction == .up ? element.laneCount - 1 : 1,
            returning: element.cVector
        )
        return "\(set)\(vectorResult(shifted, for: element))"
    }
    let i8 = x86Vector("i8")
    let i64 = x86Vector("i64")
    let (neighbour, operands) =
        switch direction {
        case .up: ("lower", ("a", "lower"))
        case .down: ("upper", ("upper", "a"))
        }
    let slid = aligned(
        "alignq\(width)",
        laneBits: 64,
        by: direction == .up ? 6 : 2,
        returning: i64
    )
    let shifted = x86Builtin(
        "palignr\(width)",
        [
            (value: operands.0, type: i8),
            (value: operands.1, type: i8),
            (value: "\(direction == .up ? 16 - element.bits / 8 : element.bits / 8)", type: "int"),
        ],
        returning: element.cVector
    )
    return """
        \(set)const \(i64) \(neighbour) = \(slid);
        \(vectorResult(shifted, for: element))
        """
}

func x86Slide1Up(for element: Element) -> String {
    vectorResult(x86SlideBytes(.up, by: 1, for: element), for: element)
}

func x86Avx3MaskBits(_ operand: String, for element: Element) -> String {
    let name = "cvt\(x86LaneLetter(bits: element.bits))2mask\(x86Bits(element.width))"
    let type = x86MaskType(lanes: element.laneCount)
    return x86Builtin(name, [operand], as: "i\(element.bits)", returning: type)
}

func x86MaskBits(for element: Element) -> String {
    guard element.width < 64 else { return x86Avx3MaskBits("mask", for: element) }
    let moves = "pmovmskb\(x86Bits(element.width))"
    switch element.bits {
    case 8:
        return x86Builtin(moves, ["mask"], as: "i8", returning: "int")
    case 16 where element.width > 16:
        return x86Builtin(moves, ["mask"], as: "i8", returning: "int")
    case 16:
        let zero = compoundLiteral(x86Vector("i16"), ["0"])
        let packed = x86Builtin(
            "packsswb128",
            ["mask", zero],
            as: "i16",
            returning: x86Vector("i8")
        )
        return x86Builtin(moves, [packed], as: "i8", returning: "int")
    case 32:
        let name = "movmskps\(x86UnsuffixedBits(element.width))"
        return x86Builtin(name, ["mask"], as: "f32", returning: "int")
    default:
        let name = "movmskpd\(x86UnsuffixedBits(element.width))"
        return x86Builtin(name, ["mask"], as: "f64", returning: "int")
    }
}

func x86MaskBitsPerLane(for element: Element) -> Int {
    element.bits == 16 && element.width == 32 ? 2 : 1
}

func x86MaskBitCount(for element: Element) -> Int {
    element.laneCount * x86MaskBitsPerLane(for: element)
}

func x86AllTrue(for element: Element) -> String {
    let bits = x86MaskBitCount(for: element)
    let allBits = "0x\(String(UInt64.max >> UInt64(64 - bits), radix: 16))"
    guard bits < 64 else { return "return \(x86MaskBits(for: element)) == \(allBits)ull;" }
    guard bits < 32 else { return "return (unsigned)\(x86MaskBits(for: element)) == \(allBits)u;" }
    return "return \(x86MaskBits(for: element)) == \(allBits);"
}

func x86TrueCount(for element: Element) -> String {
    let converted = x86MaskBitCount(for: element) > 32 ? "" : "(unsigned)"
    let count = "__builtin_popcountll((uint64_t)\(converted)\(x86MaskBits(for: element)))"
    guard x86MaskBitsPerLane(for: element) > 1 else { return "return (size_t)\(count);" }
    return "return (size_t)(\(count) >> 1);"
}

func x86FirstTrueIndex(for element: Element) -> String {
    let bitCount = x86MaskBitCount(for: element)
    let (type, typeBits, ctz) =
        bitCount > 32 ? ("uint64_t", 64, "__builtin_ctzll") : ("unsigned", 32, "__builtin_ctz")
    let topBit = String(UInt64(1) << UInt64(typeBits - 1), radix: 16)
    let suffix = typeBits == 64 ? "ull" : "u"
    let argument =
        bitCount < typeBits && element.width < 32 ? "bits | 0x\(topBit)\(suffix)" : "bits"
    let index = "\(ctz)(\(argument))"
    let lane = x86MaskBitsPerLane(for: element) > 1 ? "(\(index) >> 1)" : index
    return """
        const \(type) bits = (\(type))\(x86MaskBits(for: element));
        return bits ? (intptr_t)\(lane) : -1;
        """
}

func x86UnpackLower(_ low: String, _ high: String, laneBits: Int) -> String {
    let type = x86Vector("i\(laneBits)")
    let indices = laneIndices(unpackIndices(lanes: 128 / laneBits, upper: false))
    return "__builtin_shufflevector((\(type))\(low), (\(type))\(high), \(indices))"
}

func x86ZeroExtension(of register: String, from narrow: Element, to wide: Element) -> String {
    let zero = compoundLiteral(x86Vector("i64"), ["0"])
    var statements: [String] = []
    var source = register
    var bits = narrow.bits
    while bits < wide.bits {
        let name = "unpacked\(2 * bits)"
        let unpacked = x86UnpackLower(source, zero, laneBits: bits)
        statements.append("const \(x86Vector("i\(bits)")) \(name) = \(unpacked);")
        source = name
        bits *= 2
    }
    return (statements + [vectorResult("(\(wide.cVector))\(source)", for: wide)])
        .joined(separator: "\n")
}

func x86ShuffledZeroExtension(
    of register: String,
    from narrow: Element,
    to wide: Element
) -> String {
    let bytes = narrow.bits / 8
    let table = (0..<16).map { index -> String in
        let lane = index / 8
        let byte = index % 8
        return byte < bytes ? String(lane * bytes + byte) : "-1"
    }
    let i8 = x86Vector("i8")
    let lookup = x86Builtin("pshufb128", [register, "shuffle"], as: "i8", returning: wide.cVector)
    return """
        const \(i8) shuffle = \(compoundLiteral(i8, table));
        \(vectorResult(lookup, for: wide))
        """
}

func x86SignExtension(of register: String, from narrow: Element, to wide: Element) -> String {
    let i8 = x86Vector("i8")
    let i16 = x86Vector("i16")
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    func shifted(_ operand: String, by amount: Int, laneBits: Int) -> String {
        x86ImmediateShift(
            "psra",
            operand,
            by: "\(amount)",
            laneBits: laneBits,
            returning: wide.cVector
        )
    }
    switch (narrow.bits, wide.bits) {
    case (8, 16):
        return """
            const \(i8) pairs = \(x86UnpackLower(register, register, laneBits: 8));
            \(vectorResult(shifted("pairs", by: 8, laneBits: 16), for: wide))
            """
    case (16, 32):
        return """
            const \(i16) pairs = \(x86UnpackLower(register, register, laneBits: 16));
            \(vectorResult(shifted("pairs", by: 16, laneBits: 32), for: wide))
            """
    case (8, 32):
        return """
            const \(i8) pairs = \(x86UnpackLower(register, register, laneBits: 8));
            const \(i16) quads = \(x86UnpackLower("pairs", "pairs", laneBits: 16));
            \(vectorResult(shifted("quads", by: 24, laneBits: 32), for: wide))
            """
    case (32, 64):
        let right = x86ImmediateShift("psrl", "pairs", by: "32", laneBits: 64, returning: i64)
        let signs = x86ImmediateShift("psra", "pairs", by: "31", laneBits: 32, returning: i32)
        let sign = x86ImmediateShift("psll", "broadcast", by: "32", laneBits: 64, returning: i64)
        return """
            const \(i32) pairs = \(x86UnpackLower(register, register, laneBits: 32));
            const \(i64) right = \(right);
            const \(i32) signs = \(signs);
            const \(i32) broadcast = __builtin_shufflevector(signs, signs, 1, 1, 3, 3);
            const \(i64) sign = \(sign);
            \(vectorResult("(\(wide.cVector))(right | sign)", for: wide))
            """
    default:
        let widened: String
        if narrow.bits == 8 {
            widened = """
                const \(i8) pairs = \(x86UnpackLower(register, register, laneBits: 8));
                const \(i16) quads = \(x86UnpackLower("pairs", "pairs", laneBits: 16));
                const \(i32) lanes = (\(i32))quads >> 24;
                """
        } else {
            widened = """
                const \(i16) pairs = \(x86UnpackLower(register, register, laneBits: 16));
                const \(i32) lanes = (\(i32))pairs >> 16;
                """
        }
        let interleaved = "__builtin_shufflevector(lanes, (\(i32))signs, 0, 4, 1, 5)"
        return """
            \(widened)
            const \(i16) signs = __builtin_shufflevector(
              (\(i16))lanes, (\(i16))lanes, \(laneIndices(1..<2, 1..<2, 3..<4, 3..<4, 4..<8)));
            \(vectorResult("(\(wide.cVector))\(interleaved)", for: wide))
            """
    }
}

func x86Promotion(
    of register: String,
    from narrow: Element,
    to wide: Element,
    level: X86Level
) -> String {
    guard wide.category == .unsignedInteger else {
        return x86SignExtension(of: register, from: narrow, to: wide)
    }
    guard level == .ssse3, wide.bits == 64, narrow.bits < 32 else {
        return x86ZeroExtension(of: register, from: narrow, to: wide)
    }
    return x86ShuffledZeroExtension(of: register, from: narrow, to: wide)
}

func x86PromotionName(from narrow: Element, to wide: Element) -> String {
    "cvectorization_ops_x86_promote_\(narrow.cSuffix)_to_\(wide.cSuffix)"
}

func x86PromotionHelper(from narrow: Element, to wide: Element, level: X86Level) -> String {
    let vector = narrow.cBlock
    let lowest = laneIndices(0..<wide.laneCount)
    let converted = vectorResult(
        "__builtin_convertvector(__builtin_shufflevector(a, a, \(lowest)), \(wide.cVector))",
        for: wide
    )
    let promotion =
        narrow.category == .float || level >= .sse4
        ? converted : x86Promotion(of: "a", from: narrow, to: wide, level: level)
    return cFunction(
        returns: wide.cRawVector,
        name: x86PromotionName(from: narrow, to: wide),
        parameters: ["\(x86RawBlockType(of: narrow)) v"],
        body: "const \(vector) a = (\(vector))v;\n\(promotion)"
    )
    .trimmingCharacters(in: .newlines)
}

func x86PromotionHelpers(from narrow: Element) -> TargetBodies<Element> {
    TargetBodies(
        avx2: { wide in x86PromotionHelper(from: narrow, to: wide, level: .avx2) },
        sse4: { wide in x86PromotionHelper(from: narrow, to: wide, level: .sse4) },
        ssse3: { wide in x86PromotionHelper(from: narrow, to: wide, level: .ssse3) },
        sse2: { wide in x86PromotionHelper(from: narrow, to: wide, level: .sse2) }
    )
}

func x86Widening(takesCount: Bool, from narrow: Element, to wide: Element) -> String {
    let load =
        takesCount
        ? "\(x86LoadFirstName(lanes: wide.laneCount, for: narrow))(from, count)"
        : "\(x86PartialName("load", bytes: wide.laneCount * narrow.bits / 8, for: narrow))(from)"
    return "return \(x86PromotionName(from: narrow, to: wide))(\(load));"
}

struct ShuffleStep {
    let name: String
    let first: String
    let second: String
    let laneBits: Int
    let indices: [Int]
    var isFloating = false
    var byteShift: Int?
    var unpacksUpper: Bool?

    static func lower(
        _ name: String,
        _ first: String,
        _ second: String,
        laneBits: Int,
        isFloating: Bool = false
    ) -> Self {
        let indices = unpackIndices(lanes: 128 / laneBits, upper: false)
        return Self(
            name: name,
            first: first,
            second: second,
            laneBits: laneBits,
            indices: indices,
            isFloating: isFloating,
            unpacksUpper: false
        )
    }

    static func upper(
        _ name: String,
        _ first: String,
        _ second: String,
        laneBits: Int,
        isFloating: Bool = false
    ) -> Self {
        let indices = unpackIndices(lanes: 128 / laneBits, upper: true)
        return Self(
            name: name,
            first: first,
            second: second,
            laneBits: laneBits,
            indices: indices,
            isFloating: isFloating,
            unpacksUpper: true
        )
    }

    static func permuting(
        _ name: String,
        _ source: String,
        indices: [Int],
        laneBits: Int
    ) -> Self {
        Self(name: name, first: source, second: source, laneBits: laneBits, indices: indices)
    }

    static func byteShiftedRight(_ name: String, _ source: String, bytes: Int) -> Self {
        Self(
            name: name,
            first: source,
            second: source,
            laneBits: 64,
            indices: [],
            byteShift: bytes
        )
    }

    static func floating(
        _ name: String,
        _ first: String,
        _ second: String,
        indices: [Int],
        laneBits: Int
    ) -> Self {
        Self(
            name: name,
            first: first,
            second: second,
            laneBits: laneBits,
            indices: indices,
            isFloating: true
        )
    }
}

func x86Shuffles(
    _ steps: [ShuffleStep],
    opaqueCasts: Bool = false,
    for element: Element
) -> [String] {
    steps.map { step in
        if let bytes = step.byteShift {
            let type = x86Vector(element.category == .float ? "f\(element.bits)" : "i64")
            let shifted =
                "__builtin_ia32_psrldqi128_byteshift((\(x86Vector("i64")))\(step.first), \(bytes))"
            return "const \(type) \(step.name) = (\(type))\(shifted);"
        }
        let isNative = element.category == .float && step.laneBits == element.bits
        let type = x86Vector("\(step.isFloating || isNative ? "f" : "i")\(step.laneBits)")
        func operand(_ name: String) -> String {
            guard opaqueCasts && step.isFloating && !isNative else { return "(\(type))\(name)" }
            return "\(x86AsFloatName(bits: step.laneBits))((\(x86Vector("i64")))\(name))"
        }
        let operands = "\(operand(step.first)), \(operand(step.second))"
        let indices = laneIndices(
            step.unpacksUpper.map {
                unpackIndices(lanes: 128 / step.laneBits, upper: $0, blocks: element.width / 16)
            } ?? step.indices
        )
        return "const \(type) \(step.name) = __builtin_shufflevector(\(operands), \(indices));"
    }
}

func x86LoadInterleaved4Steps(for element: Element) -> [ShuffleStep] {
    switch element.bits {
    case 8:
        return [
            .lower("v5140", "vA", "vB", laneBits: 8),
            .lower("vd9c8", "vC", "vD", laneBits: 8),
            .upper("v7362", "vA", "vB", laneBits: 8),
            .upper("vfbea", "vC", "vD", laneBits: 8),
            .lower("v6420", "v5140", "v7362", laneBits: 8),
            .lower("veca8", "vd9c8", "vfbea", laneBits: 8),
            .upper("v7531", "v5140", "v7362", laneBits: 8),
            .upper("vfdb9", "vd9c8", "vfbea", laneBits: 8),
            .lower("v10L", "v6420", "v7531", laneBits: 8),
            .lower("v10U", "veca8", "vfdb9", laneBits: 8),
            .upper("v32L", "v6420", "v7531", laneBits: 8),
            .upper("v32U", "veca8", "vfdb9", laneBits: 8),
            .lower("r0", "v10L", "v10U", laneBits: 64),
            .upper("r1", "v10L", "v10U", laneBits: 64),
            .lower("r2", "v32L", "v32U", laneBits: 64),
            .upper("r3", "v32L", "v32U", laneBits: 64),
        ]
    case 16:
        return [
            .lower("va820", "vA", "vB", laneBits: 16),
            .lower("vec64", "vC", "vD", laneBits: 16),
            .upper("vb931", "vA", "vB", laneBits: 16),
            .upper("vfd75", "vC", "vD", laneBits: 16),
            .lower("v10b830", "va820", "vb931", laneBits: 16),
            .lower("v10fc74", "vec64", "vfd75", laneBits: 16),
            .upper("v32b830", "va820", "vb931", laneBits: 16),
            .upper("v32fc74", "vec64", "vfd75", laneBits: 16),
            .lower("r0", "v10b830", "v10fc74", laneBits: 64),
            .upper("r1", "v10b830", "v10fc74", laneBits: 64),
            .lower("r2", "v32b830", "v32fc74", laneBits: 64),
            .upper("r3", "v32b830", "v32fc74", laneBits: 64),
        ]
    case 32:
        return [
            .lower("v10e", "vA", "vC", laneBits: 32),
            .lower("v10o", "vB", "vD", laneBits: 32),
            .upper("v32e", "vA", "vC", laneBits: 32),
            .upper("v32o", "vB", "vD", laneBits: 32),
            .lower("r0", "v10e", "v10o", laneBits: 32),
            .upper("r1", "v10e", "v10o", laneBits: 32),
            .lower("r2", "v32e", "v32o", laneBits: 32),
            .upper("r3", "v32e", "v32o", laneBits: 32),
        ]
    default:
        return [
            .lower("r0", "vA", "vC", laneBits: 64),
            .upper("r1", "vA", "vC", laneBits: 64),
            .lower("r2", "vB", "vD", laneBits: 64),
            .upper("r3", "vB", "vD", laneBits: 64),
        ]
    }
}

func x86StoreInterleaved4Steps(for element: Element) -> [ShuffleStep] {
    let bits = element.bits
    guard bits < 64 else {
        return [
            .lower("vA", "a", "b", laneBits: 64),
            .lower("vB", "c", "d", laneBits: 64),
            .upper("vC", "a", "b", laneBits: 64),
            .upper("vD", "c", "d", laneBits: 64),
        ]
    }
    return [
        .lower("v10L", "a", "b", laneBits: bits),
        .lower("v32L", "c", "d", laneBits: bits),
        .upper("v10U", "a", "b", laneBits: bits),
        .upper("v32U", "c", "d", laneBits: bits),
        .lower("vA", "v10L", "v32L", laneBits: 2 * bits),
        .upper("vB", "v10L", "v32L", laneBits: 2 * bits),
        .lower("vC", "v10U", "v32U", laneBits: 2 * bits),
        .upper("vD", "v10U", "v32U", laneBits: 2 * bits),
    ]
}

func x86OddEven(
    _ name: String,
    odd: String,
    even: String,
    level: X86Level,
    for element: Element
) -> [ShuffleStep] {
    guard element.bits == 32 else {
        guard level >= .sse4 else {
            return [.floating(name, even, odd, indices: [0, 3], laneBits: 64)]
        }
        return [.floating(name, odd, even, indices: [2, 1], laneBits: 64)]
    }
    guard level >= .sse4 else {
        return [
            .permuting("\(name)Odd", odd, indices: [1, 3, 1, 3], laneBits: 32),
            .permuting("\(name)Even", even, indices: [0, 2, 0, 2], laneBits: 32),
            .lower(name, "\(name)Even", "\(name)Odd", laneBits: 32),
        ]
    }
    return [.floating(name, odd, even, indices: [4, 1, 6, 3], laneBits: 32)]
}

func x86LoadInterleaved3Steps(level: X86Level, for element: Element) -> [ShuffleStep] {
    func oddEven(_ name: String, odd: String, even: String) -> [ShuffleStep] {
        x86OddEven(name, odd: odd, even: even, level: level, for: element)
    }
    guard element.bits == 32 else {
        let indices = Array(8..<24)
        return oddEven("r0", odd: "vB", even: "vA")
            + [ShuffleStep(name: "r1", first: "vA", second: "vC", laneBits: 8, indices: indices)]
            + oddEven("r2", odd: "vC", even: "vB")
    }
    return oddEven("vxx0203xx", odd: "vC", even: "vB")
        + [.floating("r0", "vA", "vxx0203xx", indices: [0, 3, 6, 5], laneBits: 32)]
        + oddEven("vxxxx1011", odd: "vA", even: "vB")
        + oddEven("v1213xxxx", odd: "vB", even: "vC")
        + [.floating("r1", "vxxxx1011", "v1213xxxx", indices: [1, 0, 7, 6], laneBits: 32)]
        + oddEven("vxx2021xx", odd: "vB", even: "vA")
        + [.floating("r2", "vxx2021xx", "vC", indices: [2, 1, 4, 7], laneBits: 32)]
}

func x86StoreInterleaved2Steps(for element: Element) -> [ShuffleStep] {
    [
        .lower("vA", "a", "b", laneBits: element.bits),
        .upper("vB", "a", "b", laneBits: element.bits),
    ]
}

func x86StoreInterleaved3Steps(level: X86Level, for element: Element) -> [ShuffleStep] {
    func oddEven(_ name: String, odd: String, even: String) -> [ShuffleStep] {
        x86OddEven(name, odd: odd, even: even, level: level, for: element)
    }
    let isFloating = element.category == .float
    guard element.bits == 32 else {
        return [.lower("vA", "a", "b", laneBits: 64)]
            + oddEven("vB", odd: "a", even: "c")
            + [.upper("vC", "b", "c", laneBits: 64)]
    }
    return [.lower("v10v00", "a", "b", laneBits: 32)]
        + oddEven("v01v20", odd: "a", even: "c")
        + [
            .lower("vA", "v10v00", "v01v20", laneBits: 64, isFloating: isFloating),
            .byteShiftedRight("v1x321", "b", bytes: 4),
            .byteShiftedRight("v0x32", "a", bytes: 8),
        ]
        + oddEven("v21v11", odd: "c", even: "v1x321")
        + oddEven("v12v02", odd: "v1x321", even: "v0x32")
        + [
            .lower("vB", "v21v11", "v12v02", laneBits: 64, isFloating: isFloating),
            .upper("vC", "v01v20", "v21v11", laneBits: 64, isFloating: isFloating),
        ]
}

func x86LoadInterleaved(
    _ steps: [ShuffleStep],
    channels: Int,
    for element: Element
) -> String {
    let names = ["vA", "vB", "vC", "vD"].prefix(channels)
    let kind = element.category == .float ? "f" : "i"
    let declaration = "\(x86Vector("\(kind)\(element.bits)")) \(names.joined(separator: ", "));"
    let loads = names.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(index * element.laneCount), sizeof \(name));"
    }
    let shuffles = steps.flatMap { step -> [String] in
        let shuffle = x86Shuffles([step], for: element)
        guard step.name.hasPrefix("r"), let channel = Int(step.name.dropFirst()) else {
            return shuffle
        }
        let value = "(\(element.cVector))\(step.name)"
        return shuffle + [outVectorStore(channel, of: value, for: element)]
    }
    return ([declaration] + loads + shuffles).joined(separator: "\n")
}

func x86StoreInterleaved(
    _ steps: [ShuffleStep],
    channels: Int,
    for element: Element
) -> String {
    let stores = ["vA", "vB", "vC", "vD"].prefix(channels).enumerated().map { index, name in
        "__builtin_memcpy(to + \(index * element.laneCount), &\(name), sizeof \(name));"
    }
    return (x86Shuffles(steps, opaqueCasts: true, for: element) + stores).joined(separator: "\n")
}

enum X86Avx2ConcatKind {
    case lowerLower
    case lowerUpper
    case upperLower
    case upperUpper
}

func x86Avx2NativeSuffix(of element: Element) -> String {
    element.category == .float ? element.cSuffix : "i64"
}

func x86Avx2Concat(
    _ concat: X86Avx2ConcatKind,
    hi: String,
    lo: String,
    for element: Element
) -> String {
    let suffix = x86Avx2NativeSuffix(of: element)
    let vector = x86Vector(suffix)
    let isFloating = element.category == .float
    let precision = element.bits == 32 ? "ps" : "pd"
    let blockLanes = isFloating ? element.blockLaneCount : 2
    let operands = [(value: lo, type: vector), (value: hi, type: vector)]
    func permuted(_ control: Int) -> String {
        x86Builtin(
            isFloating ? "vperm2f128_\(precision)256" : "permti256",
            operands + [(value: x86Immediate(control), type: "int")],
            returning: vector
        )
    }
    switch concat {
    case .lowerLower:
        let lowerHalf = """
            __builtin_shufflevector(\
            (\(vector))\(hi), (\(vector))\(hi), \(laneIndices(0..<blockLanes)))
            """
        return x86Builtin(
            isFloating ? "vinsertf128_\(precision)256" : "insert128i256",
            [
                (value: lo, type: vector), (value: lowerHalf, type: x86Block(suffix)),
                (value: "1", type: "int"),
            ],
            returning: vector
        )
    case .lowerUpper:
        return permuted(0x21)
    case .upperLower:
        let blendType = x86Vector(isFloating ? element.cSuffix : "i32")
        let control = isFloating && element.bits == 64 ? 3 : 0x0F
        return x86Builtin(
            isFloating ? "blend\(precision)256" : "pblendd256",
            [
                (value: hi, type: blendType), (value: lo, type: blendType),
                (value: x86Immediate(control), type: "int"),
            ],
            returning: vector
        )
    case .upperUpper:
        return permuted(0x31)
    }
}

func x86Avx2LoadBlocks(channels: Int, for element: Element) -> [String] {
    let vector = x86Vector(x86Avx2NativeSuffix(of: element))
    let names = ["v10", "v32", "v54", "v76"].prefix(channels)
    let loads = names.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(index * element.laneCount), sizeof \(name));"
    }
    func block(_ name: String, _ concat: X86Avx2ConcatKind, hi: String, lo: String) -> String {
        "const \(vector) \(name) = \(x86Avx2Concat(concat, hi: hi, lo: lo, for: element));"
    }
    let blocks =
        channels == 3
        ? [
            block("vA", .upperLower, hi: "v32", lo: "v10"),
            block("vB", .lowerUpper, hi: "v54", lo: "v10"),
            block("vC", .upperLower, hi: "v54", lo: "v32"),
        ]
        : [
            block("vA", .lowerLower, hi: "v54", lo: "v10"),
            block("vB", .upperUpper, hi: "v54", lo: "v10"),
            block("vC", .lowerLower, hi: "v76", lo: "v32"),
            block("vD", .upperUpper, hi: "v76", lo: "v32"),
        ]
    return ["\(vector) \(names.joined(separator: ", "));"] + loads + blocks
}

func x86Avx2LoadInterleaved(
    _ shuffles: [String],
    channels: Int,
    for element: Element
) -> String {
    let stores = (0..<channels).map { channel in
        outVectorStore(channel, of: "(\(element.cVector))r\(channel)", for: element)
    }
    let statements = x86Avx2LoadBlocks(channels: channels, for: element) + shuffles + stores
    return statements.joined(separator: "\n")
}

func x86Avx2StoreBlocks(channels: Int, for element: Element) -> [String] {
    let vector = x86Vector(x86Avx2NativeSuffix(of: element))
    func block(_ name: String, _ concat: X86Avx2ConcatKind, hi: String, lo: String) -> String {
        "const \(vector) \(name) = \(x86Avx2Concat(concat, hi: hi, lo: lo, for: element));"
    }
    func store(_ index: Int) -> String {
        "__builtin_memcpy(to + \(index * element.laneCount), &out\(index), sizeof out\(index));"
    }
    switch channels {
    case 2:
        return [
            block("out0", .lowerLower, hi: "vB", lo: "vA"),
            block("out1", .upperUpper, hi: "vB", lo: "vA"),
            store(0), store(1),
        ]
    case 3:
        return [
            block("out0", .lowerLower, hi: "vB", lo: "vA"),
            block("out1", .upperLower, hi: "vA", lo: "vC"),
            block("out2", .upperUpper, hi: "vC", lo: "vB"),
            store(0), store(1), store(2),
        ]
    default:
        return [
            block("out0", .lowerLower, hi: "vB", lo: "vA"),
            block("out1", .lowerLower, hi: "vD", lo: "vC"),
            store(0), store(1),
            block("out2", .upperUpper, hi: "vB", lo: "vA"),
            block("out3", .upperUpper, hi: "vD", lo: "vC"),
            store(2), store(3),
        ]
    }
}

func x86Avx2StoreInterleaved(
    _ shuffles: [String],
    channels: Int,
    for element: Element
) -> String {
    (shuffles + x86Avx2StoreBlocks(channels: channels, for: element)).joined(separator: "\n")
}

func x86Avx2LoadInterleaved2(for element: Element) -> String {
    let native = x86Vector(x86Avx2NativeSuffix(of: element))
    let i64 = x86Vector("i64")
    let loads = """
        \(native) first, second;
        __builtin_memcpy(&first, from, sizeof first);
        __builtin_memcpy(&second, from + \(element.laneCount), sizeof second);
        """
    func permuted(_ operand: String) -> String {
        guard element.category == .float && element.bits == 64 else {
            return x86Builtin(
                "permdi256",
                [(value: operand, type: i64), (value: "0xD8", type: "int")],
                returning: element.cVector
            )
        }
        return x86Builtin(
            "permdf256",
            [(value: operand, type: native), (value: "0xD8", type: "int")],
            returning: element.cVector
        )
    }
    let statements: [String]
    switch element.bits {
    case 8, 16:
        let wide = x86Vector("i\(2 * element.bits)")
        let mask = splat(element.bits == 8 ? "255" : "65535", as: wide, lanes: 128 / element.bits)
        let pack = element.bits == 8 ? "packuswb256" : "packusdw256"
        func packed(_ low: String, _ high: String) -> String {
            permuted(x86Builtin(pack, [low, high], as: "i\(2 * element.bits)", returning: i64))
        }
        func shiftedRight(_ operand: String) -> String {
            x86ImmediateShift(
                "psrl",
                operand,
                by: "\(element.bits)",
                laneBits: 2 * element.bits,
                width: 32,
                returning: wide
            )
        }
        statements = [
            "const \(wide) evenLow = (\(wide))first & \(mask);",
            "const \(wide) evenHigh = (\(wide))second & \(mask);",
            "const \(element.cVector) out0 = \(packed("evenLow", "evenHigh"));",
            "const \(wide) oddHigh = \(shiftedRight("second"));",
            "const \(wide) oddLow = \(shiftedRight("first"));",
            "const \(element.cVector) out1 = \(packed("oddLow", "oddHigh"));",
        ]
    default:
        let shuffle = element.bits == 32 ? "shufps256" : "shufpd256"
        let shuffleType = x86Vector("f\(element.bits)")
        let controls = element.bits == 32 ? ["0x88", "0xDD"] : ["0", "0xF"]
        func gathered(_ control: String) -> String {
            x86Builtin(
                shuffle,
                [
                    (value: "first", type: shuffleType), (value: "second", type: shuffleType),
                    (value: control, type: "int"),
                ],
                returning: shuffleType
            )
        }
        statements = [
            "const \(shuffleType) evens = \(gathered(controls[0]));",
            "const \(element.cVector) out0 = \(permuted("evens"));",
            "const \(shuffleType) odds = \(gathered(controls[1]));",
            "const \(element.cVector) out1 = \(permuted("odds"));",
        ]
    }
    let stores = (0..<2).map { outVectorStore($0, from: "out\($0)") }
    return ([loads] + statements + stores).joined(separator: "\n")
}

func x86Avx2OddEven(
    _ name: String,
    odd: String,
    even: String,
    for element: Element
) -> String {
    let native = x86Vector(x86Avx2NativeSuffix(of: element))
    let isFloating = element.category == .float
    let (builtin, control) =
        switch (isFloating, element.bits) {
        case (true, 64): ("blendpd256", 5)
        case (true, _): ("blendps256", 0x55)
        case (false, 64): ("pblendd256", 0x33)
        default: ("pblendd256", 0x55)
        }
    let blendType = x86Vector(isFloating ? element.cSuffix : "i32")
    let blended = x86Builtin(
        builtin,
        [
            (value: odd, type: blendType), (value: even, type: blendType),
            (value: x86Immediate(control), type: "int"),
        ],
        returning: native
    )
    return "const \(native) \(name) = \(blended);"
}

func x86Avx2ByteShiftedRight(
    _ name: String,
    _ source: String,
    bytes: Int,
    for element: Element
) -> String {
    let native = x86Vector(x86Avx2NativeSuffix(of: element))
    let shifted = "__builtin_ia32_psrldqi256_byteshift((\(x86Vector("i64")))\(source), \(bytes))"
    return "const \(native) \(name) = (\(native))\(shifted);"
}

func x86Avx2TableLookupBytes(_ bytes: String, _ indices: String, into result: String) -> String {
    let type = x86Vector("i64")
    let lookup = x86Builtin("pshufb256", [bytes, indices], as: "i8", returning: type)
    return "const \(type) \(result) = \(lookup);"
}

func x86Avx2LoadInterleaved3Lookups(for element: Element) -> String {
    let blocks = ["vA", "vB", "vC"]
    let channels = x86LoadInterleaved3Tables(for: element)
    let tables = channels.flatMap { $0 }.map {
        x86ByteTable("idx\(uppercasedFirst($0.name))", $0.table + $0.table)
    }
    let lookups = channels.flatMap { channel in
        channel.enumerated().map { block, part in
            x86Avx2TableLookupBytes(
                blocks[block],
                "idx\(uppercasedFirst(part.name))",
                into: part.name
            )
        }
    }
    let combines = channels.indices.map { channel in
        let names = channels[channel].map(\.name)
        let combined = "\(names[0]) ^ (\(names[1]) ^ \(names[2]))"
        return outVectorStore(channel, of: "(\(element.cVector))(\(combined))", for: element)
    }
    return (x86Avx2LoadBlocks(channels: 3, for: element) + tables + lookups + combines)
        .joined(separator: "\n")
}

func x86Avx2LoadInterleaved3Shuffles(for element: Element) -> [String] {
    func oddEven(_ name: String, odd: String, even: String) -> String {
        x86Avx2OddEven(name, odd: odd, even: even, for: element)
    }
    guard element.bits == 32 else {
        let native = x86Vector(x86Avx2NativeSuffix(of: element))
        let i8 = x86Vector("i8")
        let aligned = x86Builtin(
            "palignr256",
            [(value: "vC", type: i8), (value: "vA", type: i8), (value: "8", type: "int")],
            returning: native
        )
        return [
            oddEven("r0", odd: "vB", even: "vA"),
            "const \(native) r1 = \(aligned);",
            oddEven("r2", odd: "vC", even: "vB"),
        ]
    }
    let f32 = x86Vector("f32")
    func shuffled(_ name: String, _ first: String, _ second: String, control: Int) -> String {
        let shuffle = x86Builtin(
            "shufps256",
            [
                (value: first, type: f32), (value: second, type: f32),
                (value: x86Immediate(control), type: "int"),
            ],
            returning: f32
        )
        return "const \(f32) \(name) = \(shuffle);"
    }
    return [
        oddEven("vxx0203xx", odd: "vC", even: "vB"),
        shuffled("r0", "vA", "vxx0203xx", control: 0x6C),
        oddEven("vxxxx1011", odd: "vA", even: "vB"),
        oddEven("v1213xxxx", odd: "vB", even: "vC"),
        shuffled("r1", "vxxxx1011", "v1213xxxx", control: 0xB1),
        oddEven("vxx2021xx", odd: "vB", even: "vA"),
        shuffled("r2", "vxx2021xx", "vC", control: 0xC6),
    ]
}

func x86Avx2StoreInterleaved3Lookups(for element: Element) -> String {
    let tables = x86StoreInterleaved3Tables(for: element)
    let blocks = ["A", "B", "C"]
    let inputs = ["a", "b", "c"]
    let declarations = zip(blocks, tables).flatMap { block, group in
        group.enumerated().map { index, table in
            x86ByteTable("shuf\(block)\(index)", table + table)
        }
    }
    let statements = blocks.flatMap { block in
        let lookups = inputs.indices.map { index in
            x86Avx2TableLookupBytes(
                inputs[index],
                "shuf\(block)\(index)",
                into: "v\(block)\(index)"
            )
        }
        let combined =
            "const \(element.cVector) v\(block) = (\(element.cVector))(v\(block)0 | v\(block)1 | v\(block)2);"
        return lookups + [combined]
    }
    return (declarations + statements + x86Avx2StoreBlocks(channels: 3, for: element))
        .joined(separator: "\n")
}

func x86Avx2StoreInterleaved3Shuffles(for element: Element) -> [String] {
    func oddEven(_ name: String, odd: String, even: String) -> String {
        x86Avx2OddEven(name, odd: odd, even: even, for: element)
    }
    func shuffles(_ steps: [ShuffleStep]) -> [String] {
        x86Shuffles(steps, opaqueCasts: true, for: element)
    }
    guard element.bits == 32 else {
        return shuffles([.lower("vA", "a", "b", laneBits: 64)])
            + [oddEven("vB", odd: "a", even: "c")]
            + shuffles([.upper("vC", "b", "c", laneBits: 64)])
    }
    let isFloating = element.category == .float
    return shuffles([.lower("v10v00", "a", "b", laneBits: 32)])
        + [oddEven("v01v20", odd: "a", even: "c")]
        + shuffles([.lower("vA", "v10v00", "v01v20", laneBits: 64, isFloating: isFloating)])
        + [
            x86Avx2ByteShiftedRight("v1x321", "b", bytes: 4, for: element),
            x86Avx2ByteShiftedRight("v0x32", "a", bytes: 8, for: element),
            oddEven("v21v11", odd: "c", even: "v1x321"),
            oddEven("v12v02", odd: "v1x321", even: "v0x32"),
        ]
        + shuffles([
            .lower("vB", "v21v11", "v12v02", laneBits: 64, isFloating: isFloating),
            .upper("vC", "v01v20", "v21v11", laneBits: 64, isFloating: isFloating),
        ])
}

func x86Avx2ConstantOperandDispatch(
    _ operands: [String],
    constant: String,
    otherwise: String,
    for element: Element
) -> String {
    let condition = operands.map {
        "__builtin_constant_p(__builtin_reduce_or(\(unsignedBits($0, of: element))))"
    }.joined(separator: " || ")
    return """
        if (\(condition)) {
        \(indented(constant))
        } else {
        \(indented(otherwise))
        }
        """
}

func x86Avx2LoadInterleaved3(for element: Element) -> String {
    switch element.bits {
    case 8:
        return shuffleLoadInterleaved(channels: 3, for: element)
    case 16:
        return x86Avx2LoadInterleaved3Lookups(for: element)
    default:
        return x86Avx2LoadInterleaved(
            x86Avx2LoadInterleaved3Shuffles(for: element),
            channels: 3,
            for: element
        )
    }
}

func x86Avx2StoreInterleaved2(for element: Element) -> String {
    let blocks = x86Avx2StoreInterleaved(
        x86Shuffles(x86StoreInterleaved2Steps(for: element), opaqueCasts: true, for: element),
        channels: 2,
        for: element
    )
    guard element.bits < 64 else { return blocks }
    return x86Avx2ConstantOperandDispatch(
        element.category == .float ? ["b"] : ["a", "b"],
        constant: shuffleStoreInterleaved(channels: 2, for: element),
        otherwise: blocks,
        for: element
    )
}

func x86Avx2StoreInterleaved3(for element: Element) -> String {
    switch element.bits {
    case 8:
        return x86Avx2ConstantOperandDispatch(
            ["a", "b", "c"],
            constant: x86Avx2StoreInterleaved3Lookups(for: element),
            otherwise: shuffleStoreInterleaved(channels: 3, for: element),
            for: element
        )
    case 16:
        return x86Avx2StoreInterleaved3Lookups(for: element)
    default:
        return x86Avx2StoreInterleaved(
            x86Avx2StoreInterleaved3Shuffles(for: element),
            channels: 3,
            for: element
        )
    }
}

func x86Avx2StoreInterleaved4(for element: Element) -> String {
    let blocks = x86Avx2StoreInterleaved(
        x86Shuffles(x86StoreInterleaved4Steps(for: element), opaqueCasts: true, for: element),
        channels: 4,
        for: element
    )
    switch element.bits {
    case 8:
        return x86Avx2ConstantOperandDispatch(
            ["a", "b", "c", "d"],
            constant: shuffleStoreInterleaved(channels: 4, for: element),
            otherwise: blocks,
            for: element
        )
    case 64:
        return shuffleStoreInterleaved(channels: 4, for: element)
    default:
        return blocks
    }
}

func x86ImmediateShift(
    _ instruction: String,
    _ operand: String,
    by amount: String,
    laneBits: Int,
    width: Int = 16,
    returning type: String
) -> String {
    let name = x86ShiftName(instruction, laneBits: laneBits)
    let vector = x86Vector("i\(laneBits)")
    return "(\(type))__builtin_ia32_\(name)i\(x86Bits(width))((\(vector))\(operand), \(amount))"
}

func x86LoadInterleaved2(level: X86Level, for element: Element) -> String {
    let i8 = x86Vector("i8")
    let i16 = x86Vector("i16")
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    let vector = element.cVector
    let loads = """
        \(i64) first, second;
        __builtin_memcpy(&first, from, sizeof first);
        __builtin_memcpy(&second, from + \(element.laneCount), sizeof second);
        """
    guard element.bits == 8 else {
        func shiftedRight(_ operand: String) -> String {
            x86ImmediateShift("psra", operand, by: "16", laneBits: 32, returning: i32)
        }
        let evens: String
        if level >= .sse4 {
            let mask = splat("0xFFFF", as: i32, lanes: 4)
            let packed = x86Builtin(
                "packusdw128",
                ["evenLow", "evenHigh"],
                as: "i32",
                returning: vector
            )
            evens = """
                const \(i32) evenLow = (\(i32))first & \(mask);
                const \(i32) evenHigh = (\(i32))second & \(mask);
                \(outVectorStore(0, of: packed, for: element))
                """
        } else if level >= .ssse3 {
            let table =
                [0x00, 0x01, 0x04, 0x05, 0x08, 0x09, 0x0C, 0x0D] + Array(repeating: 0, count: 8)
            let lookup: (String) -> String = {
                x86Builtin("pshufb128", [$0, "shuffle"], as: "i8", returning: i8)
            }
            let gathered = """
                (\(vector))__builtin_shufflevector(
                  (\(i64))evenLow, (\(i64))evenHigh, 0, 2)
                """
            evens = """
                const \(i8) shuffle = \(compoundLiteral(i8, table.map(String.init)));
                const \(i8) evenLow = \(lookup("first"));
                const \(i8) evenHigh = \(lookup("second"));
                \(outVectorStore(0, of: gathered, for: element))
                """
        } else {
            let packed = x86Builtin(
                "packssdw128",
                ["evenLow", "evenHigh"],
                as: "i32",
                returning: vector
            )
            let shiftedLeft: (String) -> String = {
                x86ImmediateShift("psll", $0, by: "16", laneBits: 32, returning: i32)
            }
            evens = """
                const \(i32) shiftedHigh = \(shiftedLeft("second"));
                const \(i32) shiftedLow = \(shiftedLeft("first"));
                const \(i32) evenHigh = \(shiftedRight("shiftedHigh"));
                const \(i32) evenLow = \(shiftedRight("shiftedLow"));
                \(outVectorStore(0, of: packed, for: element))
                """
        }
        let packed = x86Builtin("packssdw128", ["oddLow", "oddHigh"], as: "i32", returning: vector)
        return """
            \(loads)
            \(evens)
            const \(i32) oddHigh = \(shiftedRight("second"));
            const \(i32) oddLow = \(shiftedRight("first"));
            \(outVectorStore(1, of: packed, for: element))
            """
    }
    func shiftedRight(_ operand: String) -> String {
        x86ImmediateShift("psrl", operand, by: "8", laneBits: 16, returning: i16)
    }
    let mask = splat("255", as: i16, lanes: 8)
    let evens = x86Builtin("packuswb128", ["evenLow", "evenHigh"], as: "i16", returning: vector)
    let odds = x86Builtin("packuswb128", ["oddLow", "oddHigh"], as: "i16", returning: vector)
    return """
        \(loads)
        const \(i16) evenLow = (\(i16))first & \(mask);
        const \(i16) evenHigh = (\(i16))second & \(mask);
        \(outVectorStore(0, of: evens, for: element))
        const \(i16) oddHigh = \(shiftedRight("second"));
        const \(i16) oddLow = \(shiftedRight("first"));
        \(outVectorStore(1, of: odds, for: element))
        """
}

func x86LoadInterleaved3Tables(for element: Element) -> [[(name: String, table: [UInt8])]] {
    let laneBytes = element.bits / 8
    let blockLanes = 16 / laneBytes
    let parts = ["L", "M", "U"]
    return (0..<3).map { channel in
        parts.indices.map { block -> (name: String, table: [UInt8]) in
            let table = (0..<16).map { byte -> UInt8 in
                let position = 3 * (byte / laneBytes) + channel
                guard position / blockLanes == block else { return zeroedByte }
                return UInt8((position % blockLanes) * laneBytes + byte % laneBytes)
            }
            return ("v\(channel)\(parts[block])", table)
        }
    }
}

func x86LoadInterleaved3Lookups(level: X86Level, for element: Element) -> String {
    let type = x86Vector("i8")
    let blocks = ["vA", "vB", "vC"]
    let laneBytes = element.bits / 8
    let blockLanes = 16 / laneBytes
    let loads = blocks.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(blockLanes * index), sizeof \(name));"
    }
    let channels = x86LoadInterleaved3Tables(for: element)
    let tables = channels.flatMap { $0 }.map {
        x86ByteTable("idx\(uppercasedFirst($0.name))", $0.table)
    }
    let lookups = channels.flatMap { channel in
        channel.enumerated().map { block, part in
            x86TableLookupBytesOr0(
                blocks[block],
                "idx\(uppercasedFirst(part.name))",
                into: part.name,
                level: level
            )
        }
    }
    let combines = channels.indices.map { channel in
        let names = channels[channel].map(\.name)
        let combined = "\(names[0]) ^ (\(names[1]) ^ \(names[2]))"
        return outVectorStore(channel, of: "(\(element.cVector))(\(combined))", for: element)
    }
    let blockType = level < .ssse3 ? x86Vector("i64") : type
    let declaration = "\(blockType) \(blocks.joined(separator: ", "));"
    return ([declaration] + loads + tables + lookups + combines).joined(separator: "\n")
}

let zeroedByte: UInt8 = 0x80

func addingToBytes(_ table: [UInt8], _ amount: Int) -> [UInt8] {
    table.map { $0 &+ UInt8(amount) }
}

func combiningShiftRightBytes(_ high: [UInt8], _ low: [UInt8], by count: Int) -> [UInt8] {
    Array((low + high)[count..<count + 16])
}

func x86StoreInterleaved3Tables(for element: Element) -> [[[UInt8]]] {
    let z = zeroedByte
    guard element.bits == 8 else {
        let first: [UInt8] = [z, z, 0, 1, z, z, z, z, 2, 3, z, z, z, z, 4, 5]
        let second: [UInt8] = [z, z, z, z, 0, 1, z, z, z, z, 2, 3, z, z, z, z]
        let third = combiningShiftRightBytes(first, first, by: 2)
        let middle = [addingToBytes(first, 6), addingToBytes(second, 6), addingToBytes(third, 4)]
        let last = [
            addingToBytes(middle[1], 6), addingToBytes(middle[2], 6), addingToBytes(middle[0], 4),
        ]
        return [[third, first, second], middle, last]
    }
    let first: [UInt8] = [0, z, z, 1, z, z, 2, z, z, 3, z, z, 4, z, z, 5]
    let second: [UInt8] = [z, 0, z, z, 1, z, z, 2, z, z, 3, z, z, 4, z, z]
    let third = combiningShiftRightBytes(second, second, by: 15)
    let middle = [addingToBytes(third, 6), addingToBytes(first, 5), addingToBytes(second, 5)]
    let last = [
        addingToBytes(middle[2], 6), addingToBytes(middle[0], 5), addingToBytes(middle[1], 5),
    ]
    return [[first, second, third], middle, last]
}

func x86ByteTable(_ name: String, _ table: [UInt8]) -> String {
    let values = table.map { String(Int8(bitPattern: $0)) }
    return "const \(x86Vector("i8")) \(name) = {\(values.joined(separator: ", "))};"
}

func x86TableLookupBytesOr0(
    _ bytes: String,
    _ indices: String,
    into result: String,
    level: X86Level
) -> String {
    let type = x86Vector("i8")
    guard level < .ssse3 else {
        let lookup = x86Builtin("pshufb128", [bytes, indices], as: "i8", returning: type)
        return "const \(type) \(result) = \(lookup);"
    }
    let zero = compoundLiteral(type, ["0"])
    let wide = x86Vector("i64")
    return """
        const \(type) \(result)Zeroed = \(zero) > \(indices);
        \(x86EmulatedTableLookupBytes(bytes, indices, into: "\(result)Looked"))
        const \(wide) \(result) = ~(\(wide))\(result)Zeroed & \(result)Looked;
        """
}

func x86EmulatedTableLookupBytes(
    _ bytes: String,
    _ indices: String,
    into result: String
) -> String {
    let type = x86Vector("i64")
    let lookup = """
        uint8_t resultBytes[16] __attribute__((aligned(16)));
        uint8_t tableBytes[16] __attribute__((aligned(16)));
        uint8_t indexBytes[16] __attribute__((aligned(16)));
        *(\(type)*)tableBytes = (\(type))\(bytes);
        *(\(type)*)indexBytes = (\(type))\(indices);
        for (int i = 0; i < 16; i++) {
          resultBytes[i] = tableBytes[indexBytes[i] & 15];
        }
        \(result) = *(\(type)*)resultBytes;
        """
    return "\(type) \(result);\n{\n\(indented(lookup))\n}"
}

func x86StoreInterleaved3Lookups(level: X86Level, for element: Element) -> String {
    let tables = x86StoreInterleaved3Tables(for: element)
    let blocks = ["A", "B", "C"]
    let inputs = ["a", "b", "c"]
    let declarations = zip(blocks, tables).flatMap { block, group in
        group.enumerated().map { index, table in x86ByteTable("shuf\(block)\(index)", table) }
    }
    let statements = blocks.flatMap { block in
        let lookups = inputs.indices.map { index in
            x86TableLookupBytesOr0(
                inputs[index],
                "shuf\(block)\(index)",
                into: "v\(block)\(index)",
                level: level
            )
        }
        let combined =
            "const \(element.cVector) v\(block) = (\(element.cVector))(v\(block)0 | v\(block)1 | v\(block)2);"
        return lookups + [combined]
    }
    let stores = ["vA", "vB", "vC"].enumerated().map { index, name in
        "__builtin_memcpy(to + \(index * element.laneCount), &\(name), sizeof \(name));"
    }
    return (declarations + statements + stores).joined(separator: "\n")
}

func laneIndices(_ indices: [Int]) -> String {
    indices.map(String.init).joined(separator: ", ")
}

func laneIndices(_ ranges: Range<Int>...) -> String {
    laneIndices(ranges.flatMap { $0 })
}

func unpackIndices(lanes: Int, upper: Bool, blocks: Int = 1) -> [Int] {
    let start = upper ? lanes / 2 : 0
    let total = lanes * blocks
    return (0..<blocks).flatMap { block in
        (start..<start + lanes / 2).flatMap { [block * lanes + $0, total + block * lanes + $0] }
    }
}

func indented(_ code: String) -> String {
    code.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "  \($0)" }
        .joined(separator: "\n")
}

func loadFirstCases(
    lanes: Int,
    of element: Element,
    in register: String? = nil,
    full: String = "__builtin_memcpy(&v, from, sizeof v);",
    single: String?,
    partial: String,
    finish: String
) -> String {
    let vector = register ?? element.cVector
    var lines = ["\(vector) v;", "if (count >= \(lanes)) {"]
    lines += [indented(full), "} else if (count == 0) {"]
    lines += [indented("v = (\(vector)){0};")]
    if let single {
        lines += ["} else if (count == 1) {", indented(single)]
    }
    lines += ["} else {", indented(partial), "}", finish]
    return lines.joined(separator: "\n")
}

func neonUnit(bytes: Int) -> (vector: String, scalar: String) {
    switch bytes {
    case 1: return ("byte_vector", "uint8_t")
    case 2: return ("short_vector", "uint16_t")
    default: return ("word_vector", "uint32_t")
    }
}

func neonWithTypedefs(_ code: String, for element: Element) -> String {
    var declarations = [
        (
            name: "half_vector",
            line: "typedef \(element.cType) half_vector __attribute__((vector_size(8)));"
        )
    ]
    for bytes in [1, 2, 4] {
        let unit = neonUnit(bytes: bytes)
        declarations.append(
            (
                name: unit.vector,
                line: "typedef \(unit.scalar) \(unit.vector) __attribute__((vector_size(8)));"
            )
        )
    }
    declarations.append((name: "zero", line: "const half_vector zero = {0};"))
    let used = declarations.filter { code.contains($0.name) }.map(\.line)
    return (used + [code]).joined(separator: "\n")
}

func neonDuplicatedLoad(
    _ scalar: String,
    into vector: String,
    bytes: Int,
    from pointer: String,
    for element: Element
) -> String {
    let isLane = bytes == element.bits / 8
    let unit = neonUnit(bytes: bytes)
    let values = Array(repeating: scalar, count: 8 / bytes).joined(separator: ", ")
    return """
        \(isLane ? element.cType : unit.scalar) \(scalar);
        __builtin_memcpy(&\(scalar), \(pointer), sizeof \(scalar));
        const \(isLane ? "half_vector" : unit.vector) \(vector) = {\(values)};
        """
}

func neonZipLow(_ low: String, _ high: String, unitBytes: Int, groupBytes: Int? = nil) -> String {
    let unit = neonUnit(bytes: unitBytes).vector
    let group = (groupBytes ?? unitBytes) / unitBytes
    let groups = unpackIndices(lanes: 8 / unitBytes / group, upper: false)
    let indices = laneIndices(groups.flatMap { group * $0..<group * $0 + group })
    return "(half_vector)__builtin_shufflevector((\(unit))\(low), (\(unit))\(high), \(indices))"
}

func neonConcatenation(_ low: String, _ high: String, for element: Element) -> String {
    "__builtin_shufflevector(\(low), \(high), \(laneIndices(0..<element.laneCount)))"
}

func neonKeepingFirst(
    _ count: Int,
    of operand: String,
    lanes: Int,
    type: String,
    for element: Element
) -> String {
    let zeros = Array(repeating: "0", count: lanes - count)
    guard element.category == .float else {
        let kept = Array(repeating: "(\(element.cType))-1", count: count)
        return "\(operand) & \(compoundLiteral(type, kept + zeros))"
    }
    let keptBytes = Array(repeating: "-1", count: count * element.bits / 8)
    let byteLanes = keptBytes + Array(repeating: "0", count: 16 - keptBytes.count)
    let bytes = neonVector("i8")
    return "(\(type))((\(bytes))\(operand) & \(compoundLiteral(bytes, byteLanes)))"
}

func neonLoadFirst(for element: Element) -> String {
    let vector = element.cVector
    let lanes = element.laneCount
    let size = element.bits / 8
    let halfLanes = 8 / size
    func load(_ scalar: String, into name: String, bytes: Int, at pointer: String) -> String {
        neonDuplicatedLoad(scalar, into: name, bytes: bytes, from: pointer, for: element)
    }
    func zip(_ low: String, _ high: String, unitBytes: Int, groupBytes: Int? = nil) -> String {
        neonZipLow(low, high, unitBytes: unitBytes, groupBytes: groupBytes)
    }
    func concatenation(_ low: String, _ high: String) -> String {
        neonConcatenation(low, high, for: element)
    }
    func cases(single: String?, partial: String) -> String {
        neonWithTypedefs(
            loadFirstCases(
                lanes: lanes,
                of: element,
                single: single,
                partial: partial,
                finish: vectorResult("v", for: element)
            ),
            for: element
        )
    }
    let first = neonKeepingFirst(1, of: "widened", lanes: lanes, type: vector, for: element)
    let single = """
        \(load("single", into: "duplicated", bytes: size, at: "from"))
        const \(vector) widened = \(concatenation("duplicated", "zero"));
        v = \(first);
        """
    switch lanes {
    case 2:
        let partial = """
            half_vector single;
            __builtin_memcpy(&single, from, sizeof single);
            v = \(concatenation("single", "zero"));
            """
        return cases(single: nil, partial: partial)
    case 4:
        let partial = """
            half_vector pair;
            __builtin_memcpy(&pair, from, sizeof pair);
            v = \(concatenation("pair", "zero"));
            if (count != 2) {
              v[2] = from[2];
            }
            """
        return cases(single: single, partial: partial)
    case 8:
        let pair = load("pair", into: "lower", bytes: 4, at: "from + leading")
        let third = load("third", into: "duplicated", bytes: 2, at: "from + leading + 2")
        let lone = load("single", into: "duplicated", bytes: 2, at: "from + leading")
        let kept = neonKeepingFirst(
            1,
            of: "duplicated",
            lanes: halfLanes,
            type: "half_vector",
            for: element
        )
        let partial = """
            const size_t leading = count & 4;
            half_vector trailing = zero;
            if (count & 2) {
            \(indented(pair))
              if (count & 1) {
            \(indented(indented(third)))
                const half_vector upper = \(zip("duplicated", "zero", unitBytes: 2));
                trailing = \(zip("lower", "upper", unitBytes: 4));
              } else {
                trailing = \(zip("lower", "zero", unitBytes: 4));
              }
            } else if (count & 1) {
            \(indented(lone))
              trailing = \(kept);
            }
            if (leading != 0) {
              half_vector head;
              __builtin_memcpy(&head, from, sizeof head);
              v = \(concatenation("head", "trailing"));
            } else {
              v = \(concatenation("trailing", "zero"));
            }
            """
        return cases(single: single, partial: partial)
    default:
        let pair = load("pair", into: "lower", bytes: 2, at: "from + leading")
        let third = load("third", into: "duplicated", bytes: 1, at: "from + leading + 2")
        let lone = load("single", into: "duplicated", bytes: 1, at: "from + leading")
        let middle = load("bits", into: "lower", bytes: 4, at: "from + 8")
        let head = load("bits", into: "lower", bytes: 4, at: "from")
        let kept = neonKeepingFirst(
            1,
            of: "duplicated",
            lanes: halfLanes,
            type: "half_vector",
            for: element
        )
        let firstFour = neonKeepingFirst(4, of: "widened", lanes: lanes, type: vector, for: element)
        let partial = """
            const size_t leading = count & 12;
            half_vector trailing = zero;
            if (count & 2) {
            \(indented(pair))
              if (count & 1) {
            \(indented(indented(third)))
                const half_vector upper = \(zip("duplicated", "zero", unitBytes: 1));
                trailing = \(zip("lower", "upper", unitBytes: 2));
              } else {
                trailing = \(zip("lower", "zero", unitBytes: 1, groupBytes: 2));
              }
            } else if (count & 1) {
            \(indented(lone))
              trailing = \(kept);
            }
            if (leading != 0) {
              if (leading >= 8) {
                half_vector upper;
                if (leading & 4) {
            \(indented(indented(indented(middle))))
                  upper = \(zip("lower", "trailing", unitBytes: 4));
                } else {
                  upper = \(zip("trailing", "zero", unitBytes: 4));
                }
                half_vector lower;
                __builtin_memcpy(&lower, from, sizeof lower);
                v = \(concatenation("lower", "upper"));
              } else {
            \(indented(indented(head)))
                const half_vector combined = \(zip("lower", "trailing", unitBytes: 4));
                v = \(concatenation("combined", "zero"));
              }
            } else {
              const \(vector) widened = \(concatenation("trailing", "zero"));
              v = \(firstFour);
            }
            """
        return cases(single: single, partial: partial)
    }
}

func neonLoadFirstWidening(from narrow: Element, to wide: Element) -> String {
    let lanes = wide.laneCount
    let size = narrow.bits / 8
    let bytes = lanes * size
    func load(_ scalar: String, into name: String, bytes: Int, at pointer: String) -> String {
        neonDuplicatedLoad(scalar, into: name, bytes: bytes, from: pointer, for: narrow)
    }
    func zip(_ low: String, _ high: String, unitBytes: Int, groupBytes: Int? = nil) -> String {
        neonZipLow(low, high, unitBytes: unitBytes, groupBytes: groupBytes)
    }
    let kept = neonKeepingFirst(
        1,
        of: "duplicated",
        lanes: 8 / size,
        type: "half_vector",
        for: narrow
    )
    let full: String
    if bytes == 8 {
        full = "__builtin_memcpy(&v, from, sizeof v);"
    } else {
        full = """
            \(load("bits", into: "duplicated", bytes: bytes, at: "from"))
            v = (half_vector)duplicated;
            """
    }
    let single = """
        \(load("single", into: "duplicated", bytes: size, at: "from"))
        v = \(kept);
        """
    let partial: String
    switch lanes {
    case 2:
        partial = """
            \(load("single", into: "duplicated", bytes: size, at: "from"))
            v = \(zip("duplicated", "zero", unitBytes: size));
            """
    case 4:
        partial = """
            \(load("pair", into: "duplicated", bytes: 2 * size, at: "from"))
            v = \(zip("duplicated", "zero", unitBytes: 2 * size));
            if (count != 2) {
              v[2] = from[2];
            }
            """
    default:
        let pair = load("pair", into: "lower", bytes: 2, at: "from + leading")
        let third = load("third", into: "duplicated", bytes: 1, at: "from + leading + 2")
        let lone = load("single", into: "duplicated", bytes: 1, at: "from + leading")
        let head = load("bits", into: "lower", bytes: 4, at: "from")
        partial = """
            const size_t leading = count & 4;
            half_vector trailing = zero;
            if (count & 2) {
            \(indented(pair))
              if (count & 1) {
            \(indented(indented(third)))
                const half_vector upper = \(zip("duplicated", "zero", unitBytes: 1));
                trailing = \(zip("lower", "upper", unitBytes: 2));
              } else {
                trailing = \(zip("lower", "zero", unitBytes: 1, groupBytes: 2));
              }
            } else if (count & 1) {
            \(indented(lone))
              trailing = \(kept);
            }
            if (leading != 0) {
            \(indented(head))
              v = \(zip("lower", "trailing", unitBytes: 4));
            } else {
              v = \(zip("trailing", "zero", unitBytes: 4));
            }
            """
    }
    let low = bytes == 8 ? "v" : "__builtin_shufflevector(v, v, \(laneIndices(0..<lanes)))"
    let converted = "__builtin_convertvector(\(low), \(wide.cVector))"
    return neonWithTypedefs(
        loadFirstCases(
            lanes: lanes,
            of: narrow,
            in: "half_vector",
            full: full,
            single: lanes == 2 ? nil : single,
            partial: partial,
            finish: vectorResult(converted, for: wide)
        ),
        for: narrow
    )
}

func x86PartialName(_ operation: String, bytes: Int, floatBits: Int? = nil) -> String {
    let suffix = floatBits.map { "_f\($0)" } ?? ""
    return "cvectorization_ops_x86_\(operation)_\(bytes)_bytes\(suffix)"
}

func x86PartialName(_ operation: String, bytes: Int, for element: Element) -> String {
    let floatBits = element.category == .float ? element.bits : nil
    return x86PartialName(operation, bytes: bytes, floatBits: floatBits)
}

func x86InterleaveLowerName(bits: Int) -> String {
    "cvectorization_ops_x86_interleave_lower_i\(bits)"
}

func x86InsertLaneName(_ lane: Int, for element: Element) -> String {
    "cvectorization_ops_x86_insert_lane_\(lane)_\(element.cSuffix)"
}

func x86PartialLoadHelpers() -> [String] {
    let i32 = x86Block("i32")
    let i64 = x86Block("i64")
    let f32 = x86Block("f32")
    let f64 = x86Block("f64")
    let words = [1, 2, 4].map { bytes in
        cFunction(
            returns: i64,
            name: x86PartialName("load", bytes: bytes),
            parameters: ["const void* from"],
            body: """
                int32_t bits = 0;
                __builtin_memcpy(&bits, from, \(bytes));
                return (\(i64))(\(i32)){bits, 0, 0, 0};
                """
        )
    }
    let long = cFunction(
        returns: i64,
        name: x86PartialName("load", bytes: 8),
        parameters: ["const void* from"],
        body: """
            long long bits;
            __builtin_memcpy(&bits, from, 8);
            return (\(i64)){bits, 0};
            """
    )
    let single = cFunction(
        returns: f32,
        name: x86PartialName("load", bytes: 4, floatBits: 32),
        parameters: ["const void* from"],
        body: """
            float value;
            __builtin_memcpy(&value, from, 4);
            return (\(f32)){value, 0, 0, 0};
            """
    )
    let pair = cFunction(
        returns: f32,
        name: x86PartialName("load", bytes: 8, floatBits: 32),
        parameters: ["const void* from"],
        body: """
            typedef float pair_vector __attribute__((vector_size(8)));
            pair_vector value;
            __builtin_memcpy(&value, from, 8);
            return __builtin_shufflevector(value, (pair_vector){0}, 0, 1, 2, 3);
            """
    )
    let lone = cFunction(
        returns: f64,
        name: x86PartialName("load", bytes: 8, floatBits: 64),
        parameters: ["const void* from"],
        body: """
            double value;
            __builtin_memcpy(&value, from, 8);
            return (\(f64)){value, 0};
            """
    )
    let wholes: [(floatBits: Int?, type: String)] = [(nil, i64), (32, f32), (64, f64)]
    let whole = wholes.map { floatBits, type in
        cFunction(
            returns: type,
            name: x86PartialName("load", bytes: 16, floatBits: floatBits),
            parameters: ["const void* from"],
            body: """
                \(type) value;
                __builtin_memcpy(&value, from, 16);
                return value;
                """
        )
    }
    return words + [long, single, pair, lone] + whole
}

func x86InterleaveLowerHelpers() -> [String] {
    let i64 = x86Block("i64")
    return [16, 32, 64].map { bits in
        let unit = x86Block("i\(bits)")
        let indices = laneIndices(unpackIndices(lanes: 128 / bits, upper: false))
        return cFunction(
            returns: i64,
            name: x86InterleaveLowerName(bits: bits),
            parameters: ["\(i64) low", "\(i64) high"],
            body: "return (\(i64))__builtin_shufflevector((\(unit))low, (\(unit))high, \(indices));"
        )
    }
}

func laneMask(_ lane: Int, for element: Element) -> String {
    var lanes = Array(repeating: "0", count: element.laneCount)
    lanes[lane] = "-1"
    return compoundLiteral(element.cMask, lanes)
}

func x86InsertLane(_ lane: Int, for element: Element) -> String {
    let vector = element.cVector
    let block = element.cBlock
    let inserted = """
        \(block) a = (\(block))rawA;
        a[\(lane)] = t;
        return (\(x86RawBlockType(of: element)))a;
        """
    let selected = x86BitSelect("selected", repeatingVector("t", of: element), "a", for: element)
    let blended = """
        const \(vector) a = (\(vector))rawA;
        const \(element.cMask) selected = \(laneMask(lane, for: element));
        \(vectorResult(selected, for: element))
        """
    let levels = TargetBodies<Element>(
        avx2: { _ in inserted },
        sse4: { _ in inserted },
        sse2: { _ in blended }
    )
    return cFunction(
        returns: x86RawBlockType(of: element),
        name: x86InsertLaneName(lane, for: element),
        parameters: ["\(x86RawBlockType(of: element)) rawA", "\(element.cType) t"],
        body: element.bits == 16 ? inserted : cBody(levels, for: element, portable: nil)
    )
}

func x86LoadFirstName(lanes: Int, for element: Element) -> String {
    "cvectorization_ops_x86_load_first_\(lanes)_\(element.cSuffix)"
}

func x86PartialLoadFirstLanes(of element: Element) -> [Int] {
    let wides = elements.filter { wide in
        wideningSources(of: wide).contains { $0.cSuffix == element.cSuffix }
    }
    return Set(wides.map { $0.at(width: element.width).laneCount }).sorted()
}

func x86LoadFirstHelperLanes(for element: Element) -> [Int] {
    let partialLanes = x86PartialLoadFirstLanes(of: element)
    guard element.width > 16 else { return partialLanes }
    return Set(partialLanes + [element.blockLaneCount]).sorted()
}

func x86LoadFirstHelpers(for element: Element) -> String? {
    let helperLanes = x86LoadFirstHelperLanes(for: element)
    let loadedLanes = element.width > 16 ? helperLanes : [element.laneCount] + helperLanes
    var helpers: [String] = []
    if loadedLanes.contains(4) {
        helpers.append(x86InsertLane(2, for: element))
    }
    helpers += helperLanes.map { lanes in
        cFunction(
            returns: x86RawBlockType(of: element),
            name: x86LoadFirstName(lanes: lanes, for: element),
            parameters: ["const \(element.cType)* from", "size_t count"],
            body: x86LoadFirst(lanes: lanes, for: element)
        )
    }
    return helpers.isEmpty ? nil : helpers.joined().trimmingCharacters(in: .newlines)
}

/// Highway's `LoadN`, with a call wherever Highway calls an op, so that LLVM simplifies each part
/// before inlining it the way it does Highway's. `StoreN`s follow the same structure.
func x86LoadFirstWide(for element: Element) -> String {
    let lanes = element.laneCount
    let halfLanes = element.blockLaneCount
    let block = element.cBlock
    let raw = x86RawBlockType(of: element)
    let half = x86LoadFirstName(lanes: halfLanes, for: element)
    let whole = x86PartialName("load", bytes: 16, for: element)
    let zero = "(\(block)){0}"
    let indices = laneIndices(0..<lanes)
    let extended = "__builtin_shufflevector((\(block))lower, \(zero), \(indices))"
    let combined = "__builtin_shufflevector((\(block))lower, (\(block))upper, \(indices))"
    return """
        if (count >= \(lanes)) {
          return \(cFunctionName("load", element))(from);
        }
        if (count <= \(halfLanes)) {
          const \(raw) lower = \(half)(from, count);
          \(vectorResult(extended, for: element))
        }
        const \(raw) lower = \(whole)(from);
        const \(raw) upper = \(half)(from + \(halfLanes), count - \(halfLanes));
        \(vectorResult(combined, for: element))
        """
}

func x86LoadFirst(lanes: Int, for element: Element) -> String {
    let size = element.bits / 8
    let raw = x86RawBlockType(of: element)
    let zero = "(\(raw)){0}"
    func load(_ lanes: Int, at pointer: String) -> String {
        "\(x86PartialName("load", bytes: lanes * size, for: element))(\(pointer))"
    }
    func interleaving(_ low: String, _ high: String, halfLanes: Int) -> String {
        "\(x86InterleaveLowerName(bits: 8 * halfLanes * size))(\(low), \(high))"
    }
    let head = """
        if (count >= \(lanes)) {
          return \(load(lanes, at: "from"));
        }
        if (count == 0) {
          return \(zero);
        }
        """
    guard lanes > 2 else {
        return "\(head)\nreturn \(load(1, at: "from"));"
    }
    let single = """
        \(head)
        if (count == 1) {
          return \(load(1, at: "from"));
        }
        """
    guard lanes > 4 else {
        let inserted = "\(x86InsertLaneName(2, for: element))(pair, from[2])"
        return """
            \(single)
            const \(raw) pair = \(load(2, at: "from"));
            return count == 2 ? pair : \(inserted);
            """
    }
    let third = load(1, at: "from + leading + 2")
    let trailing = """
        \(single)
        const size_t leading = count & \(lanes - 4);
        \(raw) trailing = \(zero);
        if (count & 2) {
          const \(raw) pair = \(load(2, at: "from + leading"));
          if (count & 1) {
            trailing = \(interleaving("pair", third, halfLanes: 2));
          } else {
            trailing = pair;
          }
        } else if (count & 1) {
          trailing = \(load(1, at: "from + leading"));
        }
        """
    guard lanes > 8 else {
        return """
            \(trailing)
            if (leading != 0) {
              return \(interleaving(load(4, at: "from"), "trailing", halfLanes: 4));
            }
            return trailing;
            """
    }
    let upper = interleaving(load(4, at: "from + 8"), "trailing", halfLanes: 4)
    return """
        \(trailing)
        if (leading != 0) {
          if (leading >= 8) {
            const \(raw) upper = (leading & 4) != 0 ? \(upper) : trailing;
            return \(interleaving(load(8, at: "from"), "upper", halfLanes: 8));
          }
          return \(interleaving(load(4, at: "from"), "trailing", halfLanes: 4));
        }
        return trailing;
        """
}

func neonHalfVector(of element: Element) -> String {
    "cvectorization_ops_neon_half_\(element.cSuffix)"
}

func neonHelperName(_ operation: String, bytes: Int? = nil, for element: Element) -> String {
    let size = bytes.map { "_\($0)_bytes" } ?? ""
    return "cvectorization_ops_neon_\(operation)\(size)_\(element.cSuffix)"
}

func neonStoreFirstName(lanes: Int, for element: Element) -> String {
    "cvectorization_ops_neon_store_first_\(lanes)_\(element.cSuffix)"
}

func neonPartialStore(bytes: Int, for element: Element) -> String {
    switch bytes {
    case 8:
        return "__builtin_memcpy(to, &v, sizeof v);"
    case element.bits / 8:
        return "to[0] = v[0];"
    default:
        let unit = neonUnit(bytes: bytes)
        return """
            typedef \(unit.scalar) \(unit.vector) __attribute__((vector_size(8)));
            const \(unit.scalar) bits = ((\(unit.vector))v)[0];
            __builtin_memcpy(to, &bits, sizeof bits);
            """
    }
}

func neonStoreFirstTree(lanes: Int, of vector: String, for element: Element) -> String {
    let size = element.bits / 8
    let isFullVector = lanes == element.laneCount
    func half(_ part: String) -> String {
        isFullVector ? "\(neonHelperName("\(part)_half", for: element))(\(vector))" : vector
    }
    func store(_ lanes: Int, of source: String, at offset: Int = 0) -> String {
        let pointer = offset == 0 ? "to" : "to + \(offset)"
        let function =
            lanes == element.laneCount
            ? cFunctionName("store", element)
            : neonHelperName("store", bytes: lanes * size, for: element)
        return "\(function)(\(source), \(pointer));"
    }
    func upperHalf(_ lanes: Int) -> String {
        guard !isFullVector else { return half("upper") }
        return "\(neonHelperName("upper_half", bytes: lanes * size, for: element))(\(vector))"
    }
    switch lanes {
    case 2:
        return """
            if (count > 1) {
              \(store(2, of: vector))
            } else if (count == 1) {
              \(store(1, of: half("lower")))
            }
            """
    case 4:
        return """
            if (count > 1) {
              if (count >= 4) {
                \(store(4, of: vector))
              } else {
                \(store(2, of: half("lower")))
                if (count == 3) {
                  \(store(1, of: upperHalf(2), at: 2))
                }
              }
            } else if (count == 1) {
              \(store(1, of: half("lower")))
            }
            """
    default:
        let next = neonStoreFirstName(lanes: lanes / 2, for: element)
        return """
            if (count <= 1) {
              if (count == 1) {
                \(store(1, of: half("lower")))
              }
            } else if (count >= \(lanes)) {
              \(store(lanes, of: vector))
            } else if (count >= \(lanes / 2)) {
              \(store(lanes / 2, of: half("lower")))
              \(next)(\(upperHalf(lanes / 2)), to + \(lanes / 2), count - \(lanes / 2));
            } else {
              \(next)(\(half("lower")), to, count);
            }
            """
    }
}

func neonStoreFirstHelpers(for element: Element) -> String {
    let vector = element.cVector
    let half = neonHalfVector(of: element)
    let size = element.bits / 8
    let lanes = element.laneCount
    var helpers = ["typedef \(element.cType) \(half) __attribute__((vector_size(8)));\n"]
    var halves = [("lower", 0..<lanes / 2)]
    if lanes > 2 {
        halves.append(("upper", lanes / 2..<lanes))
    }
    helpers += halves.map { part, range in
        cFunction(
            returns: half,
            name: neonHelperName("\(part)_half", for: element),
            parameters: ["\(vector) v"],
            body: "return __builtin_shufflevector(v, v, \(laneIndices(range)));"
        )
    }
    let halfLevels = [4, 8].filter { $0 < lanes }
    helpers += halfLevels.map { level in
        let bytes = level / 2 * size
        return cFunction(
            returns: half,
            name: neonHelperName("upper_half", bytes: bytes, for: element),
            parameters: ["\(half) v"],
            body: """
                typedef uint8_t byte_vector __attribute__((vector_size(8)));
                const byte_vector zero = {0};
                return (\(half))__builtin_shufflevector((byte_vector)v, zero, \(laneIndices(bytes..<bytes + 8)));
                """
        )
    }
    helpers += [1, 2, 4, 8].filter { $0 >= size }.map { bytes in
        cFunction(
            returns: "void",
            name: neonHelperName("store", bytes: bytes, for: element),
            parameters: ["\(half) v", "\(element.cType)* to"],
            body: neonPartialStore(bytes: bytes, for: element)
        )
    }
    helpers += halfLevels.map { level in
        cFunction(
            returns: "void",
            name: neonStoreFirstName(lanes: level, for: element),
            parameters: ["\(half) v", "\(element.cType)* to", "size_t count"],
            body: neonStoreFirstTree(lanes: level, of: "v", for: element)
        )
    }
    return helpers.joined().trimmingCharacters(in: .newlines)
}

func neonStoreFirst(for element: Element) -> String {
    neonStoreFirstTree(lanes: element.laneCount, of: "a", for: element)
}

func x86StoreFirstName(lanes: Int, for element: Element) -> String {
    "cvectorization_ops_x86_store_first_\(lanes)_\(element.cSuffix)"
}

func x86PartialStoreHelpers() -> [String] {
    let i64 = x86Block("i64")
    let f32 = x86Block("f32")
    let f64 = x86Block("f64")
    let words = [1, 2, 4].map { bytes in
        cFunction(
            returns: "void",
            name: x86PartialName("store", bytes: bytes),
            parameters: ["\(i64) v", "void* to"],
            body: "__builtin_memcpy(to, &v, \(bytes));"
        )
    }
    let long = cFunction(
        returns: "void",
        name: x86PartialName("store", bytes: 8),
        parameters: ["\(i64) v", "void* to"],
        body: """
            const long long bits = v[0];
            __builtin_memcpy(to, &bits, sizeof bits);
            """
    )
    let single = cFunction(
        returns: "void",
        name: x86PartialName("store", bytes: 4, floatBits: 32),
        parameters: ["\(f32) v", "float* to"],
        body: "to[0] = v[0];"
    )
    let pair = cFunction(
        returns: "void",
        name: x86PartialName("store", bytes: 8, floatBits: 32),
        parameters: ["\(f32) v", "float* to"],
        body: """
            typedef float pair_vector __attribute__((vector_size(8)));
            const pair_vector bits = __builtin_shufflevector(v, v, 0, 1);
            __builtin_memcpy(to, &bits, sizeof bits);
            """
    )
    let lone = cFunction(
        returns: "void",
        name: x86PartialName("store", bytes: 8, floatBits: 64),
        parameters: ["\(f64) v", "double* to"],
        body: "to[0] = v[0];"
    )
    let wholes: [(floatBits: Int?, type: String)] = [(nil, i64), (32, f32), (64, f64)]
    let whole = wholes.map { floatBits, type in
        cFunction(
            returns: "void",
            name: x86PartialName("store", bytes: 16, floatBits: floatBits),
            parameters: ["\(type) v", "void* to"],
            body: "__builtin_memcpy(to, &v, 16);"
        )
    }
    return words + [long, single, pair, lone] + whole
}

func x86UpperHalfHelpers() -> [String] {
    let i8 = x86Block("i8")
    let i64 = x86Block("i64")
    let f32 = x86Block("f32")
    let shifted = [2, 4].map { bytes in
        let indices = laneIndices(bytes..<bytes + 16)
        return cFunction(
            returns: i64,
            name: x86PartialName("upper_half", bytes: bytes),
            parameters: ["\(i64) v"],
            body: "return (\(i64))__builtin_shufflevector((\(i8))v, (\(i8)){0}, \(indices));"
        )
    }
    let long = cFunction(
        returns: i64,
        name: x86PartialName("upper_half", bytes: 8),
        parameters: ["\(i64) v"],
        body: "return __builtin_shufflevector(v, v, 1, 3);"
    )
    let pair = cFunction(
        returns: f32,
        name: x86PartialName("upper_half", bytes: 8, floatBits: 32),
        parameters: ["\(f32) v"],
        body: "return __builtin_shufflevector(v, v, 6, 7, 2, 3);"
    )
    return shifted + [long, pair]
}

func x86StoreFirstTree(lanes: Int, of vector: String, for element: Element) -> String {
    let size = element.bits / 8
    func store(_ lanes: Int, of source: String, at offset: Int = 0) -> String {
        let pointer = offset == 0 ? "to" : "to + \(offset)"
        let function = x86PartialName("store", bytes: lanes * size, for: element)
        return "\(function)(\(source), \(pointer));"
    }
    func upperHalf(_ lanes: Int) -> String {
        "\(x86PartialName("upper_half", bytes: lanes * size, for: element))(\(vector))"
    }
    switch lanes {
    case 2:
        return """
            if (count > 1) {
              \(store(2, of: vector))
            } else if (count == 1) {
              \(store(1, of: vector))
            }
            """
    case 4:
        return """
            if (count > 1) {
              if (count >= 4) {
                \(store(4, of: vector))
              } else {
                \(store(2, of: vector))
                if (count == 3) {
                  \(store(1, of: upperHalf(2), at: 2))
                }
              }
            } else if (count == 1) {
              \(store(1, of: vector))
            }
            """
    default:
        let half = lanes / 2
        let next = x86StoreFirstName(lanes: half, for: element)
        return """
            if (count <= 1) {
              if (count == 1) {
                \(store(1, of: vector))
              }
            } else if (count >= \(lanes)) {
              \(store(lanes, of: vector))
            } else if (count >= \(half)) {
              \(store(half, of: vector))
              \(next)(\(upperHalf(half)), to + \(half), count - \(half));
            } else {
              \(next)(\(vector), to, count);
            }
            """
    }
}

func x86StoreFirstHelpers(for element: Element) -> String? {
    let raw = x86RawBlockType(of: element)
    let helpers = [4, 8].filter { $0 < element.laneCount }.map { lanes in
        cFunction(
            returns: "void",
            name: x86StoreFirstName(lanes: lanes, for: element),
            parameters: ["\(raw) v", "\(element.cType)* to", "size_t count"],
            body: x86StoreFirstTree(lanes: lanes, of: "v", for: element)
        )
    }
    return helpers.isEmpty ? nil : helpers.joined().trimmingCharacters(in: .newlines)
}

func x86MaskedStoreTypes(for element: Element) -> (name: String, value: String, mask: String) {
    switch (element.category, element.bits) {
    case (.float, 32): return ("maskstoreps256", "f32", "i32")
    case (.float, _): return ("maskstorepd256", "f64", "i64")
    case (_, 64): return ("maskstoreq256", "i64", "i64")
    default: return ("maskstored256", "i32", "i32")
    }
}

func x86StoreFirstTrailing(for element: Element) -> String {
    let size = element.bits / 8
    let words = "words[stored / \(4 / size)]"
    guard size == 1 else {
        return "to[stored - 1] = (\(element.cType))\(words);"
    }
    return """
        const uint32_t word = (uint32_t)\(words);
        if (stored & 2) {
          const uint16_t bits = (uint16_t)word;
          to[stored - 1] = (\(element.cType))(word >> 16);
          __builtin_memcpy(to + (stored & ~(size_t)3), &bits, sizeof bits);
        } else {
          to[stored - 1] = (\(element.cType))word;
        }
        """
}

func x86StoreFirstMasked(for element: Element) -> String {
    let types = x86MaskedStoreTypes(for: element)
    let store = x86Builtin(
        types.name,
        [
            (value: "to", type: "\(x86Vector(types.value))*"),
            (value: "mask", type: x86Vector(types.mask)),
            (value: "a", type: x86Vector(types.value)),
        ],
        returning: "void"
    )
    guard element.bits < 32 else {
        return "\(signedFirstLanesMask(for: element))\n\(store);"
    }
    let words = x86Vector("i32")
    let trailingLanes = 4 / (element.bits / 8) - 1
    return """
        const size_t stored = \(clampedCount(to: element.laneCount));
        const \(words) words = (\(words))a;
        \(signedFirstLanesMask(for: element))
        \(store);
        if ((stored & \(trailingLanes)) != 0) {
        \(indented(x86StoreFirstTrailing(for: element)))
        }
        """
}

func x86StoreFirst(for element: Element) -> String {
    let raw = x86RawType(of: element)
    return """
        const \(raw) v = (\(raw))a;
        \(x86StoreFirstTree(lanes: element.laneCount, of: "v", for: element))
        """
}

func x86Avx3LoadFirst(for element: Element) -> String {
    let lanes = element.laneCount
    let register = x86Vector(x86LaneSuffix(of: element))
    let loaded = x86Builtin(
        x86MaskedAccessName("load", width: element.width, for: element),
        [
            (
                value: "from",
                type: "const \(x86MaskedPointee(of: register, width: element.width, for: element))*"
            ),
            (value: compoundLiteral(register, ["0"]), type: register),
            (value: x86FirstLanesBits(lanes: lanes), type: x86MaskType(lanes: lanes)),
        ],
        returning: element.cVector
    )
    return vectorResult(loaded, for: element)
}

func x86Avx3StoreFirst(for element: Element) -> String {
    let lanes = element.laneCount
    let register = x86Vector(x86LaneSuffix(of: element))
    let store = x86Builtin(
        x86MaskedAccessName("store", width: element.width, for: element),
        [
            (
                value: "to",
                type: "\(x86MaskedPointee(of: register, width: element.width, for: element))*"
            ),
            (value: "a", type: register),
            (value: x86FirstLanesBits(lanes: lanes), type: x86MaskType(lanes: lanes)),
        ],
        returning: "void"
    )
    return "\(store);"
}

func x86Avx3Widening(from narrow: Element, to wide: Element) -> String {
    let bytes = wide.laneCount * narrow.bits / 8
    return """
        typedef \(narrow.cType) narrow_vector __attribute__((vector_size(\(bytes))));
        narrow_vector v;
        __builtin_memcpy(&v, from, sizeof v);
        \(vectorResult("__builtin_convertvector(v, \(wide.cVector))", for: wide))
        """
}

func x86Avx3LoadFirstWidening(from narrow: Element, to wide: Element) -> String {
    let lanes = wide.laneCount
    let bytes = lanes * narrow.bits / 8
    let registerBytes = max(bytes, 16)
    let register = "register_vector"
    let loaded = x86Builtin(
        x86MaskedAccessName("load", width: registerBytes, for: narrow),
        [
            (
                value: "from",
                type: "const \(x86MaskedPointee(of: register, width: registerBytes, for: narrow))*"
            ),
            (value: compoundLiteral(register, ["0"]), type: register),
            (
                value: x86FirstLanesBits(
                    lanes: lanes,
                    all: "0x\(String(UInt64.max >> (64 - lanes), radix: 16))ull"
                ),
                type: x86MaskType(lanes: registerBytes / (narrow.bits / 8))
            ),
        ],
        returning: register
    )
    return """
        typedef \(x86LaneType(of: narrow)) \(register) __attribute__((vector_size(\(registerBytes))));
        typedef \(narrow.cType) narrow_vector __attribute__((vector_size(\(bytes))));
        const \(register) loaded = \(loaded);
        narrow_vector v;
        __builtin_memcpy(&v, &loaded, sizeof v);
        \(vectorResult("__builtin_convertvector(v, \(wide.cVector))", for: wide))
        """
}

func shuffleLoadInterleaved(channels: Int, for element: Element) -> String {
    let lanes = element.laneCount
    let splits = (0..<channels).map { channel in
        let indices = laneIndices((0..<lanes).map { channels * $0 + channel })
        let split = "__builtin_shufflevector(all, all, \(indices))"
        return """
            const \(element.cVector) r\(channel) = (\(element.cVector))\(split);
            \(outVectorStore(channel))
            """
    }
    return """
        typedef \(element.cUnsignedLane) wide_vector __attribute__((vector_size(\(element.width * channels))));
        wide_vector all;
        __builtin_memcpy(&all, from, \(element.width * channels));
        \(splits.joined(separator: "\n"))
        """
}

func shuffleStoreInterleaved(channels: Int, for element: Element) -> String {
    let lanes = element.laneCount
    let type = element.cUnsignedLane
    let inputs = ["a", "b", "c", "d"].prefix(channels).map { unsignedBits($0, of: element) }
    let both = laneIndices(0..<2 * lanes)
    let single = laneIndices(Array(0..<lanes) + Array(repeating: -1, count: lanes))
    let interleaved = laneIndices(
        (0..<lanes).flatMap { lane in (0..<channels).map { $0 * lanes + lane } }
    )
    let wideBytes = element.width * channels
    let wide = "typedef \(type) wide_vector __attribute__((vector_size(\(wideBytes))));"
    let pair = "typedef \(type) pair_vector __attribute__((vector_size(\(2 * element.width))));"
    let shuffle = "__builtin_shufflevector"
    var statements: [String]
    let operands: String
    switch channels {
    case 2:
        statements = [wide]
        operands = "\(inputs[0]), \(inputs[1])"
    case 3:
        statements = [
            pair, wide,
            "const pair_vector ab = \(shuffle)(\(inputs[0]), \(inputs[1]), \(both));",
            "const pair_vector cc = \(shuffle)(\(inputs[2]), \(inputs[2]), \(single));",
        ]
        operands = "ab, cc"
    default:
        statements = [
            pair, wide,
            "const pair_vector ab = \(shuffle)(\(inputs[0]), \(inputs[1]), \(both));",
            "const pair_vector cd = \(shuffle)(\(inputs[2]), \(inputs[3]), \(both));",
        ]
        operands = "ab, cd"
    }
    statements.append("const wide_vector all = \(shuffle)(\(operands), \(interleaved));")
    statements.append("__builtin_memcpy(to, &all, \(element.width * channels));")
    return statements.joined(separator: "\n")
}

func x86Avx3Permutation(_ letters: String) -> Int {
    let blocks = Array("ABCD")
    return letters.reduce(0) { $0 * 4 + blocks.firstIndex(of: $1)! }
}

func x86Avx3Shuffle128(
    _ name: String,
    _ first: String,
    _ second: String,
    permutation: String,
    for element: Element
) -> String {
    let (builtin, suffix) =
        switch (element.category, element.bits) {
        case (.float, 32): ("shuf_f32x4", "f32")
        case (.float, _): ("shuf_f64x2", "f64")
        default: ("shuf_i64x2", "i64")
        }
    let type = x86Vector(suffix)
    let shuffled = x86Builtin(
        builtin,
        [
            (value: first, type: type), (value: second, type: type),
            (value: String(x86Avx3Permutation(permutation)), type: "int"),
        ],
        returning: type
    )
    return "const \(type) \(name) = \(shuffled);"
}

func x86Avx3LoadBlocks(_ names: [String], for element: Element) -> [String] {
    let kind = element.category == .float ? "f\(element.bits)" : "i64"
    let declaration = "\(x86Vector(kind)) \(names.joined(separator: ", "));"
    let loads = names.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(index * element.laneCount), sizeof \(name));"
    }
    return [declaration] + loads
}

func x86Avx3LoadResults(_ channels: Range<Int>) -> [String] {
    channels.map { outVectorStore($0) }
}

func x86Avx3LoadTransposedBlocks3(for element: Element) -> [String] {
    let loads = x86Avx3LoadBlocks(["v3210", "v7654", "vba98"], for: element)
    let blocks: [X86Avx3BlockStep] = [
        ("v5421", "v3210", "v7654", "BACB"),
        ("va976", "v7654", "vba98", "CBDC"),
        ("vA", "v3210", "va976", "CADA"),
        ("vB", "v5421", "va976", "DBCA"),
        ("vC", "v5421", "vba98", "DADB"),
    ]
    return loads + x86Avx3BlockShuffles(blocks, for: element)
}

func x86Avx3LoadTransposedBlocks4(for element: Element) -> [String] {
    let loads = x86Avx3LoadBlocks(["v3210", "v7654", "vba98", "vfedc"], for: element)
    let blocks: [X86Avx3BlockStep] = [
        ("v5410", "v3210", "v7654", "BABA"),
        ("vdc98", "vba98", "vfedc", "BABA"),
        ("v7632", "v3210", "v7654", "DCDC"),
        ("vfeba", "vba98", "vfedc", "DCDC"),
        ("vA", "v5410", "vdc98", "CACA"),
        ("vB", "v5410", "vdc98", "DBDB"),
        ("vC", "v7632", "vfeba", "CACA"),
        ("vD", "v7632", "vfeba", "DBDB"),
    ]
    return loads + x86Avx3BlockShuffles(blocks, for: element)
}

func x86Avx3LoadInterleaved4(for element: Element) -> String {
    let blocks = x86Avx3LoadTransposedBlocks4(for: element)
    let shuffles = x86Shuffles(x86LoadInterleaved4Steps(for: element), for: element)
    return (blocks + shuffles + x86Avx3LoadResults(0..<4)).joined(separator: "\n")
}

func x86Avx3Xor3(
    _ first: String,
    _ second: String,
    _ third: String,
    for element: Element
) -> String {
    let i64 = x86Vector("i64")
    return x86Builtin(
        "pternlogq\(x86Bits(element.width))_mask",
        [
            (value: first, type: i64),
            (value: second, type: i64),
            (value: third, type: i64),
            (value: "0x96", type: "int"),
            (value: "-1", type: x86MaskType(lanes: element.width / 8)),
        ],
        returning: i64
    )
}

func x86Avx3RegisterVector(of element: Element) -> String {
    x86Vector(element.category == .float ? "f\(element.bits)" : "i64")
}

func x86Avx3LaneVector(of element: Element) -> String {
    x86Vector(element.category == .float ? "f\(element.bits)" : "i\(element.bits)")
}

func x86Avx3OddEven(
    _ name: String,
    odd: String,
    even: String,
    for element: Element
) -> String {
    let lane = x86Avx3LaneVector(of: element)
    let register = x86Avx3RegisterVector(of: element)
    let lanes = element.laneCount
    let indices = laneIndices((0..<lanes).map { $0 % 2 == 0 ? lanes + $0 : $0 })
    let blended = "__builtin_shufflevector((\(lane))\(odd), (\(lane))\(even), \(indices))"
    return "const \(register) \(name) = (\(register))\(blended);"
}

func x86Avx3ShuffleTwo(
    _ name: String,
    _ first: String,
    _ second: String,
    permutation: String,
    for element: Element
) -> String {
    let f32 = x86Vector("f32")
    let register = x86Avx3RegisterVector(of: element)
    let shuffled = x86Builtin(
        "shufps512",
        [
            (value: first, type: f32), (value: second, type: f32),
            (value: String(x86Avx3Permutation(permutation)), type: "int"),
        ],
        returning: register
    )
    return "const \(register) \(name) = \(shuffled);"
}

func x86Avx3LoadInterleaved3Lookups(for element: Element) -> [String] {
    let laneBytes = element.bits / 8
    let blockLanes = 16 / laneBytes
    let blocks = ["vA", "vB", "vC"]
    let parts = ["L", "M", "U"]
    let channels = (0..<3).map { channel in
        parts.indices.map { block -> (name: String, table: [UInt8]) in
            let table = (0..<16).map { byte -> UInt8 in
                let position = 3 * (byte / laneBytes) + channel
                guard position / blockLanes == block else { return zeroedByte }
                return UInt8((position % blockLanes) * laneBytes + byte % laneBytes)
            }
            return ("v\(channel)\(parts[block])", table)
        }
    }
    let i8 = x86Vector("i8")
    let tables = channels.flatMap { $0 }.map { part in
        let wide = Array(repeating: part.table, count: element.width / 16).flatMap { $0 }
        return x86ByteTable("idx\(uppercasedFirst(part.name))", wide)
    }
    let lookups = channels.flatMap { channel in
        channel.enumerated().map { block, part in
            let lookup = x86Builtin(
                "pshufb\(x86Bits(element.width))",
                [blocks[block], "idx\(uppercasedFirst(part.name))"],
                as: "i8",
                returning: i8
            )
            return "const \(i8) \(part.name) = \(lookup);"
        }
    }
    let combines = channels.indices.map { channel in
        let names = channels[channel].map(\.name)
        let combined = x86Avx3Xor3(names[0], names[1], names[2], for: element)
        return "const \(x86Vector("i64")) r\(channel) = \(combined);"
    }
    return tables + lookups + combines
}

func x86Avx3LoadInterleaved3(for element: Element) -> String {
    let i8 = x86Vector("i8")
    let register = x86Avx3RegisterVector(of: element)
    let combines: [String]
    switch element.bits {
    case 8, 16:
        combines = x86Avx3LoadInterleaved3Lookups(for: element)
    case 32:
        combines = [
            x86Avx3OddEven("vxx0203xx", odd: "vC", even: "vB", for: element),
            x86Avx3ShuffleTwo("r0", "vA", "vxx0203xx", permutation: "BCDA", for: element),
            x86Avx3OddEven("vxxxx1011", odd: "vA", even: "vB", for: element),
            x86Avx3OddEven("v1213xxxx", odd: "vB", even: "vC", for: element),
            x86Avx3ShuffleTwo("r1", "vxxxx1011", "v1213xxxx", permutation: "CDAB", for: element),
            x86Avx3OddEven("vxx2021xx", odd: "vB", even: "vA", for: element),
            x86Avx3ShuffleTwo("r2", "vxx2021xx", "vC", permutation: "DABC", for: element),
        ]
    default:
        let shifted = x86Builtin(
            "palignr\(x86Bits(element.width))",
            [(value: "vC", type: i8), (value: "vA", type: i8), (value: "8", type: "int")],
            returning: i8
        )
        combines = [
            x86Avx3OddEven("r0", odd: "vB", even: "vA", for: element),
            "const \(register) r1 = (\(register))\(shifted);",
            x86Avx3OddEven("r2", odd: "vC", even: "vB", for: element),
        ]
    }
    let blocks = x86Avx3LoadTransposedBlocks3(for: element)
    return (blocks + combines + x86Avx3LoadResults(0..<3)).joined(separator: "\n")
}

func x86Avx3LoadInterleaved2(level: X86Level, for element: Element) -> String {
    let loads = x86Avx3LoadBlocks(["vA", "vB"], for: element)
    let combines =
        element.bits == 8 && level < .avx3dl
        ? x86Avx3LoadInterleaved2Packs(for: element)
        : x86Avx3LoadInterleaved2Permutes(for: element)
    return (loads + combines + x86Avx3LoadResults(0..<2)).joined(separator: "\n")
}

func x86Avx3LoadInterleaved2Permutes(for element: Element) -> [String] {
    let lane = x86Avx3LaneVector(of: element)
    return (0..<2).map { channel in
        let indices = laneIndices((0..<element.laneCount).map { 2 * $0 + channel })
        let shuffled = "__builtin_shufflevector((\(lane))vA, (\(lane))vB, \(indices))"
        return "const \(lane) r\(channel) = \(shuffled);"
    }
}

func x86Avx3LoadInterleaved2Packs(for element: Element) -> [String] {
    let i16 = x86Vector("i16")
    let i64 = x86Vector("i64")
    let mask = splat("255", as: i16, lanes: element.width / 2)
    let order = compoundLiteral(i64, ["0", "2", "4", "6", "1", "3", "5", "7"])
    func packedBytes(_ high: String, _ low: String) -> String {
        let packed = x86Builtin(
            "packuswb\(x86Bits(element.width))",
            [(value: low, type: i16), (value: high, type: i16)],
            returning: i64
        )
        return x86Builtin(
            "permvardi\(x86Bits(element.width))",
            [(value: packed, type: i64), (value: order, type: i64)],
            returning: i64
        )
    }
    func shiftedRight(_ operand: String) -> String {
        x86ImmediateShift(
            "psrl",
            operand,
            by: "8",
            laneBits: 16,
            width: element.width,
            returning: i16
        )
    }
    return [
        "const \(i16) evenLow = (\(i16))vA & \(mask);",
        "const \(i16) evenHigh = (\(i16))vB & \(mask);",
        "const \(i64) r0 = \(packedBytes("evenHigh", "evenLow"));",
        "const \(i16) oddHigh = \(shiftedRight("vB"));",
        "const \(i16) oddLow = \(shiftedRight("vA"));",
        "const \(i64) r1 = \(packedBytes("oddHigh", "oddLow"));",
    ]
}

typealias X86Avx3BlockStep = (name: String, first: String, second: String, permutation: String)

func x86Avx3BlockShuffles(_ steps: [X86Avx3BlockStep], for element: Element) -> [String] {
    steps.map { name, first, second, permutation in
        x86Avx3Shuffle128(name, first, second, permutation: permutation, for: element)
    }
}

func x86Avx3Shuffles(_ steps: [ShuffleStep], for element: Element) -> [String] {
    let raws = ["a": "rawA", "b": "rawB", "c": "rawC", "d": "rawD"]
    return x86Shuffles(
        steps.map { step in
            ShuffleStep(
                name: step.name,
                first: raws[step.first] ?? step.first,
                second: raws[step.second] ?? step.second,
                laneBits: step.laneBits,
                indices: step.indices,
                isFloating: step.isFloating,
                byteShift: step.byteShift,
                unpacksUpper: step.unpacksUpper
            )
        },
        opaqueCasts: true,
        for: element
    )
}

func x86Avx3StoreInterleaved(
    _ statements: [String],
    blocks: [X86Avx3BlockStep],
    for element: Element
) -> String {
    let outputs = blocks.filter { $0.name.hasPrefix("out") }
    let stores = outputs.indices.map { index in
        "__builtin_memcpy(to + \(index * element.laneCount), &out\(index), sizeof out\(index));"
    }
    return (statements + x86Avx3BlockShuffles(blocks, for: element) + stores)
        .joined(separator: "\n")
}

func x86Avx3StoreInterleaved2(for element: Element) -> String {
    x86Avx3StoreInterleaved(
        x86Avx3Shuffles(x86StoreInterleaved2Steps(for: element), for: element),
        blocks: [
            ("j1j0i1i0", "vA", "vB", "BABA"),
            ("j3j2i3i2", "vA", "vB", "DCDC"),
            ("out0", "j1j0i1i0", "j1j0i1i0", "DBCA"),
            ("out1", "j3j2i3i2", "j3j2i3i2", "DBCA"),
        ],
        for: element
    )
}

func x86Avx3StoreInterleaved4(for element: Element) -> String {
    x86Avx3StoreInterleaved(
        x86Avx3Shuffles(x86StoreInterleaved4Steps(for: element), for: element),
        blocks: [
            ("j1j0i1i0", "vA", "vB", "BABA"),
            ("l1l0k1k0", "vC", "vD", "BABA"),
            ("j3j2i3i2", "vA", "vB", "DCDC"),
            ("l3l2k3k2", "vC", "vD", "DCDC"),
            ("out0", "j1j0i1i0", "l1l0k1k0", "CACA"),
            ("out1", "j1j0i1i0", "l1l0k1k0", "DBDB"),
            ("out2", "j3j2i3i2", "l3l2k3k2", "CACA"),
            ("out3", "j3j2i3i2", "l3l2k3k2", "DBDB"),
        ],
        for: element
    )
}

func x86Avx3StoreInterleaved3Lookups(for element: Element) -> [String] {
    let i8 = x86Vector("i8")
    let register = x86Vector("i64")
    let tables = x86StoreInterleaved3Tables(for: element)
    let blocks = ["A", "B", "C"]
    let inputs = ["rawA", "rawB", "rawC"]
    let declarations = zip(blocks, tables).flatMap { block, group in
        group.enumerated().map { index, table in
            let wide = Array(repeating: table, count: element.width / 16).flatMap { $0 }
            return x86ByteTable("shuf\(block)\(index)", wide)
        }
    }
    let statements = blocks.flatMap { block in
        let lookups = inputs.indices.map { index in
            let lookup = x86Builtin(
                "pshufb\(x86Bits(element.width))",
                [(value: inputs[index], type: i8), (value: "shuf\(block)\(index)", type: i8)],
                returning: i8
            )
            return "const \(i8) v\(block)\(index) = \(lookup);"
        }
        let combined =
            "const \(register) v\(block) = (\(register))(v\(block)0 | v\(block)1 | v\(block)2);"
        return lookups + [combined]
    }
    return declarations + statements
}

func x86Avx3ByteShiftedRight(
    _ name: String,
    _ source: String,
    bytes: Int,
    for element: Element
) -> String {
    let register = x86Avx3RegisterVector(of: element)
    let i64 = x86Vector("i64")
    let shifted =
        "__builtin_ia32_psrldqi\(x86Bits(element.width))_byteshift((\(i64))\(source), \(bytes))"
    return "const \(register) \(name) = (\(register))\(shifted);"
}

func x86Avx3OddEvenStep(
    _ name: String,
    odd: String,
    even: String,
    for element: Element
) -> ShuffleStep {
    let lanes = element.laneCount
    return ShuffleStep(
        name: name,
        first: odd,
        second: even,
        laneBits: element.bits,
        indices: (0..<lanes).map { $0 % 2 == 0 ? lanes + $0 : $0 }
    )
}

func x86Avx3StoreInterleaved3Shuffles(for element: Element) -> [String] {
    func oddEven(_ name: String, odd: String, even: String) -> ShuffleStep {
        x86Avx3OddEvenStep(name, odd: odd, even: even, for: element)
    }
    let isFloating = element.category == .float
    guard element.bits == 32 else {
        return x86Avx3Shuffles(
            [
                .lower("vA", "a", "b", laneBits: 64),
                oddEven("vB", odd: "a", even: "c"),
                .upper("vC", "b", "c", laneBits: 64),
            ],
            for: element
        )
    }
    func shuffles(_ steps: [ShuffleStep]) -> [String] {
        x86Avx3Shuffles(steps, for: element)
    }
    return shuffles([
        .lower("v10v00", "a", "b", laneBits: 32),
        oddEven("v01v20", odd: "a", even: "c"),
        .lower("vA", "v10v00", "v01v20", laneBits: 64, isFloating: isFloating),
    ])
        + [
            x86Avx3ByteShiftedRight("v1x321", "rawB", bytes: 4, for: element),
            x86Avx3ByteShiftedRight("v0x32", "rawA", bytes: 8, for: element),
        ]
        + shuffles([
            oddEven("v21v11", odd: "c", even: "v1x321"),
            oddEven("v12v02", odd: "v1x321", even: "v0x32"),
            .lower("vB", "v21v11", "v12v02", laneBits: 64, isFloating: isFloating),
            .upper("vC", "v01v20", "v21v11", laneBits: 64, isFloating: isFloating),
        ])
}

func x86Avx3StoreInterleaved3(for element: Element) -> String {
    x86Avx3StoreInterleaved(
        element.bits <= 16
            ? x86Avx3StoreInterleaved3Lookups(for: element)
            : x86Avx3StoreInterleaved3Shuffles(for: element),
        blocks: [
            ("j2j0i2i0", "vA", "vB", "CACA"),
            ("i3i1k2k0", "vC", "vA", "DBCA"),
            ("j3j1k3k1", "vC", "vB", "DBDB"),
            ("out0", "j2j0i2i0", "i3i1k2k0", "CACA"),
            ("out1", "j3j1k3k1", "j2j0i2i0", "DBAC"),
            ("out2", "i3i1k2k0", "j3j1k3k1", "BDDB"),
        ],
        for: element
    )
}

func x86Avx3StoreInterleaved2Halves(for element: Element) -> String {
    let vector = element.cUnsignedVector
    let lanes = element.laneCount
    let half = lanes / 2
    func halfOf(_ name: String, _ operand: String, _ range: Range<Int>) -> String {
        let source = "(\(vector))\(operand)"
        return
            "const half_vector \(name) = __builtin_shufflevector(\(source), \(source), \(laneIndices(range)));"
    }
    let interleaved = laneIndices((0..<half).flatMap { [$0, half + $0] })
    return """
        typedef \(element.cUnsignedLane) half_vector __attribute__((vector_size(\(element.width / 2))));
        \(halfOf("aLow", "rawA", 0..<half))
        \(halfOf("aHigh", "rawA", half..<lanes))
        \(halfOf("bLow", "rawB", 0..<half))
        \(halfOf("bHigh", "rawB", half..<lanes))
        const \(vector) low = __builtin_shufflevector(aLow, bLow, \(interleaved));
        const \(vector) high = __builtin_shufflevector(aHigh, bHigh, \(interleaved));
        __builtin_memcpy(to, &low, sizeof low);
        __builtin_memcpy(to + \(lanes), &high, sizeof high);
        """
}

func x86Avx3StoreInterleaved2Spread(for element: Element) -> String {
    let bytes = x86Vector("i8")
    let quads = x86Vector("i64")
    let quadLanes = element.width / 8
    let unpacked = laneIndices(unpackIndices(lanes: 16, upper: false, blocks: element.width / 16))
    func spread(_ name: String, _ operand: String, from start: Int) -> String {
        let indices = laneIndices((start..<start + quadLanes / 2).flatMap { [$0, -1] })
        let source = "(\(quads))\(operand)"
        return "const \(quads) \(name) = __builtin_shufflevector(\(source), \(source), \(indices));"
    }
    func interleave(_ name: String, _ first: String, _ second: String) -> String {
        let operands = "(\(bytes))\(first), (\(bytes))\(second)"
        return "const \(bytes) \(name) = __builtin_shufflevector(\(operands), \(unpacked));"
    }
    return """
        \(spread("lowA", "rawA", from: 0))
        \(spread("highA", "rawA", from: quadLanes / 2))
        \(spread("lowB", "rawB", from: 0))
        \(spread("highB", "rawB", from: quadLanes / 2))
        \(interleave("out0", "lowA", "lowB"))
        \(interleave("out1", "highA", "highB"))
        __builtin_memcpy(to, &out0, sizeof out0);
        __builtin_memcpy(to + \(element.laneCount), &out1, sizeof out1);
        """
}

func x86Avx3StoreInterleaved4Permutes(for element: Element) -> String {
    let lane = x86Avx3LaneVector(of: element)
    let wide = x86Vector("i\(2 * element.bits)")
    let lanes = element.laneCount
    let wideLanes = lanes / 2
    func paired(_ name: String, _ first: String, _ second: String, from start: Int) -> String {
        let indices = laneIndices((start..<start + lanes / 2).flatMap { [$0, lanes + $0] })
        let operands = "(\(lane))\(first), (\(lane))\(second)"
        return "const \(lane) \(name) = __builtin_shufflevector(\(operands), \(indices));"
    }
    func merged(_ name: String, _ first: String, _ second: String, from start: Int) -> String {
        let indices = laneIndices((start..<start + wideLanes / 2).flatMap { [$0, wideLanes + $0] })
        let operands = "(\(wide))\(first), (\(wide))\(second)"
        return "const \(wide) \(name) = __builtin_shufflevector(\(operands), \(indices));"
    }
    let shuffles = [
        paired("v10L", "rawA", "rawB", from: 0),
        paired("v32L", "rawC", "rawD", from: 0),
        paired("v10U", "rawA", "rawB", from: lanes / 2),
        paired("v32U", "rawC", "rawD", from: lanes / 2),
        merged("out0", "v10L", "v32L", from: 0),
        merged("out1", "v10L", "v32L", from: wideLanes / 2),
        merged("out2", "v10U", "v32U", from: 0),
        merged("out3", "v10U", "v32U", from: wideLanes / 2),
    ]
    let stores = (0..<4).map { index in
        "__builtin_memcpy(to + \(index * lanes), &out\(index), sizeof out\(index));"
    }
    return (shuffles + stores).joined(separator: "\n")
}

func x86Avx3LoadInterleaved2Body(level: X86Level, for element: Element) -> String {
    if element.bits == 8 && level < .avx3dl {
        return shuffleLoadInterleaved(channels: 2, for: element)
    }
    return x86Avx3LoadInterleaved2(level: level, for: element)
}

func x86Avx3LoadInterleaved3Body(for element: Element) -> String {
    if element.bits == 16 || element.bits == 32 {
        return shuffleLoadInterleaved(channels: 3, for: element)
    }
    return x86Avx3LoadInterleaved3(for: element)
}

func x86Avx3StoreInterleaved2Body(level: X86Level, for element: Element) -> String {
    if element.bits == 64 {
        return shuffleStoreInterleaved(channels: 2, for: element)
    }
    if element.bits == 8 && level < .avx3dl {
        return x86Avx3StoreInterleaved2Spread(for: element)
    }
    return element.category == .float
        ? x86Avx3StoreInterleaved2(for: element)
        : x86Avx3StoreInterleaved2Halves(for: element)
}

func x86Avx3StoreInterleaved3Body(for element: Element) -> String {
    if element.bits == 16 || element.bits == 32 {
        return shuffleStoreInterleaved(channels: 3, for: element)
    }
    return x86Avx3StoreInterleaved3(for: element)
}

func x86Avx3StoreInterleaved4Doubles(for element: Element) -> String {
    let constant = "__builtin_constant_p(__builtin_reduce_or((\(x86Vector("i64")))rawC))"
    return """
        if (\(constant)) {
        \(shuffleStoreInterleaved(channels: 4, for: element))
        } else {
        \(x86Avx3StoreInterleaved4(for: element))
        }
        """
}

func x86Avx3StoreInterleaved4Body(for element: Element) -> String {
    switch (element.category, element.bits) {
    case (.float, 64):
        return x86Avx3StoreInterleaved4Doubles(for: element)
    case (.float, _), (_, 8), (_, 64):
        return x86Avx3StoreInterleaved4(for: element)
    default:
        return x86Avx3StoreInterleaved4Permutes(for: element)
    }
}

struct LookupSize {
    let lanes: Int
    let applies: Applies
}

let lookupSizes = [
    LookupSize(lanes: 8, applies: .all(bits: [16, 32, 64])),
    LookupSize(lanes: 16, applies: .all(bits: [16, 32, 64])),
    LookupSize(lanes: 32, applies: .integer(bits: [8])),
    LookupSize(lanes: 64, applies: .integer(bits: [8])),
]

func canLookupName(_ lanes: Int) -> String {
    "canLookup\(lanes)"
}

func canLookupBody(_ lanes: Int, for element: Element) -> String {
    let enough = "return sizeof(\(element.cVector)) / sizeof(\(element.cType)) >= \(lanes / 2);"
    guard lanes == 64 else { return enough }
    return """
        #if \(neonCondition) == \(ArmLevel.neon.rawValue)
        return true;
        #else
        \(enough)
        #endif
        """
}

func lookupChecks(of op: Op, for element: Element) -> [Check] {
    guard takesLookupIndices(op), case .table(let lanes)? = op.span else { return [] }
    return indexChecks(of: op, for: element)
        + [(canLookupName(lanes), "Vector has too few lanes for this lookup")]
}

func lookupAssertions(of op: Op, for element: Element) -> String {
    lookupChecks(of: op, for: element)
        .map { "        assert(\($0.condition), \"\($0.message)\")\n" }.joined()
}

func canLookupMembers(for element: Element) -> String {
    var output = ""
    for size in lookupSizes where size.applies.matches(element) {
        let name = canLookupName(size.lanes)
        output += "    @export(implementation) @inline(always)\n"
        output += "    public static var \(name): Bool { \(cFunctionName(name, element))() }\n\n"
    }
    return output
}

func lookupBody(lanes: Int, aligned: Bool, for element: Element) -> String {
    let vector = element.cVector
    let raw = element.cRawVector
    func pointer(_ expression: String, alignment: Int) -> String {
        aligned ? "__builtin_assume_aligned(\(expression), \(alignment))" : expression
    }
    guard element.laneCount >= lanes else {
        let function = cFunctionName("twoTablesLookupLanes", element)
        return """
            \(vector) first;
            \(vector) second;
            __builtin_memcpy(&first, \(pointer("from", alignment: element.width)), sizeof first);
            __builtin_memcpy(&second, \(pointer("from + \(lanes / 2)", alignment: element.width)), sizeof second);
            return \(function)((\(raw))first, (\(raw))second, rawIndices);
            """
    }
    let bytes = lanes * element.bits / 8
    let function = cFunctionName("tableLookupLanes", element)
    let table = pointer("from", alignment: bytes)
    let load =
        bytes < element.width
        ? zeroExtendedLoad(from: table, bytes: bytes, for: element)
        : "\(vector) table;\n__builtin_memcpy(&table, \(table), \(bytes));"
    return """
        \(load)
        return \(function)((\(raw))table, rawIndices);
        """
}

func zeroExtendedLoad(from pointer: String, bytes: Int, for element: Element) -> String {
    let words = bytes / 8
    let part = bytes == 16 ? x86Block("i64") : "half_vector"
    let size = "vector_size(\(bytes))"
    let typedef = bytes == 16 ? "" : "typedef long long half_vector __attribute__((\(size)));\n"
    let zeros = compoundLiteral(part, Array(repeating: "0", count: words))
    let indices = (0..<element.width / 8).map { $0 < words ? $0 : words + ($0 - words) % words }
    let extended = "__builtin_shufflevector(loaded, \(zeros), \(laneIndices(indices)))"
    return """
        \(typedef)\(part) loaded;
        __builtin_memcpy(&loaded, \(pointer), \(bytes));
        const \(element.cVector) table = (\(element.cVector))\(extended);
        """
}

func neonLookup64(for element: Element) -> String {
    let tables = (0..<4).map { block in
        "\(element.cVector) table\(block);\n"
            + "__builtin_memcpy(&table\(block), from + \(16 * block), 16);"
    }
    let names = (0..<4).map { "table\($0)" } + ["indices"]
    let lookup = neonBuiltin("vqtbl4q_v", names, code: 48, for: element)
    return "\(tables.joined(separator: "\n"))\n\(vectorResult(lookup, for: element))"
}

func lookupOp(_ size: LookupSize) -> Op {
    let lanes = size.lanes
    func aligned(_ element: Element) -> String {
        lookupBody(lanes: lanes, aligned: true, for: element)
    }
    return Op(
        "lookup\(lanes)",
        "Lookup\(lanes)",
        [.tag, .constLanePointer, .lookupIndices],
        .vector,
        size.applies,
        span: .table(lanes: lanes),
        indexContract: .table(lanes: lanes),
        targets: TargetBodies(
            neon: { element in lanes == 64 ? neonLookup64(for: element) : nil },
            sve2_128: { element in
                lanes == 64 ? lookupBody(lanes: lanes, aligned: false, for: element) : nil
            },
            avx3: aligned,
            avx2: aligned,
            sse2: aligned
        )
    ) { element in
        lookupBody(lanes: lanes, aligned: false, for: element)
    }
}

let basicOps: [Op] = [
    Op("zero", "Zero", [.tag], .vector, .all) { element in
        vectorResult(compoundLiteral(element.cVector, ["0"]), for: element)
    },
    Op("repeating", "Set", [.tag, .lane], .vector, .all) { element in
        vectorResult(splat("value", as: element.cVector, lanes: element.laneCount), for: element)
    },
    Op(
        "iota",
        "Iota",
        [.tag, .lane],
        .vector,
        .all,
        targets: TargetBodies(sve2_128: { element in sveIota(for: element) })
    ) { element in
        let lanes = element.laneCount
        switch element.category {
        case .unsignedInteger, .float:
            let first = splat("value", as: element.cVector, lanes: lanes)
            return vectorResult(
                "\(first) + \(iota(as: element.cVector, lanes: lanes))",
                for: element
            )
        case .signedInteger:
            let type = element.cUnsignedVector
            let first = splat("(\(element.cUnsignedLane))value", as: type, lanes: lanes)
            let sum = "(\(element.cVector))(\(first) + \(iota(as: type, lanes: lanes)))"
            return vectorResult(sum, for: element)
        }
    },

    Op("load", "LoadU", [.tag, .constLanePointer], .vector, .all, span: .vectors(1)) { element in
        loadedVector(from: "from", for: element)
    },
    Op(
        "loadAligned",
        "Load",
        [.tag, .constLanePointer],
        .vector,
        .all,
        span: .vectors(1, aligned: true),
        targets: TargetBodies(
            avx3: { element in
                loadedVector(from: assumedAligned("from", for: element), for: element)
            },
            avx2: { element in
                loadedVector(from: assumedAligned("from", for: element), for: element)
            },
            sse2: { element in
                loadedVector(from: assumedAligned("from", for: element), for: element)
            }
        )
    ) { element in
        loadedVector(from: "from", for: element)
    },
    Op(
        "loadFirst",
        "LoadN",
        [.tag, .constLanePointer, .count],
        .vector,
        .all,
        span: .first,
        constantArgument: ConstantArgument(
            name: "count",
            cast: "(uint32_t)",
            applies: { element in
                element.bits >= 32 && !(element.category == .float && element.bits == 32)
            }
        ),
        targets: TargetBodies(
            neon: { element in neonLoadFirst(for: element) },
            sve2_128: { element in sveLoadFirst(for: element) },
            avx3: { element in x86Avx3LoadFirst(for: element) },
            avx2: { element in x86LoadFirstWide(for: element) },
            sse2: { element in x86LoadFirst(lanes: element.laneCount, for: element) }
        ),
        spanTargets: TargetBodies(
            sve2_128: { element in sveLoadFirst(for: element, spanned: true) }
        ),
        helpers: TargetBodies(
            avx2: { element in x86LoadFirstHelpers(for: element) },
            sse2: { element in x86LoadFirstHelpers(for: element) }
        )
    ) { element in
        let size = "\(clampedCount(to: element.laneCount)) * sizeof(\(element.cType))"
        return """
            const size_t size = \(size);
            \(zeroedVector(of: element.cVector))
            __builtin_memcpy(&v, from, size);
            \(vectorResult("v", for: element))
            """
    },
    Op("store", "StoreU", [.vector, .tag, .lanePointer], .void, .all, span: .vectors(1)) { _ in
        storedVector(to: "to")
    },
    Op(
        "storeAligned",
        "Store",
        [.vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(1, aligned: true),
        targets: TargetBodies(
            avx3: { element in storedVector(to: assumedAligned("to", for: element)) },
            avx2: { element in storedVector(to: assumedAligned("to", for: element)) },
            sse2: { element in storedVector(to: assumedAligned("to", for: element)) }
        )
    ) { _ in
        storedVector(to: "to")
    },
    Op(
        "storeFirst",
        "StoreN",
        [.vector, .tag, .lanePointer, .count],
        .void,
        .all,
        span: .first,
        constantArgument: ConstantArgument(
            name: "count",
            holds: { element in "((count & (count - 1)) == 0 || count >= \(element.laneCount))" }
        ),
        targets: TargetBodies(
            neon: { element in neonStoreFirst(for: element) },
            sve2_128: { element in sveStoreFirst(for: element) },
            avx3: { element in x86Avx3StoreFirst(for: element) },
            avx2: { element in x86StoreFirstMasked(for: element) },
            sse2: { element in x86StoreFirst(for: element) }
        ),
        helpers: TargetBodies(
            neon: { element in neonStoreFirstHelpers(for: element) },
            sse2: { element in x86StoreFirstHelpers(for: element) }
        )
    ) { element in
        let size = "\(clampedCount(to: element.laneCount)) * sizeof(\(element.cType))"
        return "__builtin_memcpy(to, &a, \(size));"
    },

    Op(
        "adding",
        "Add",
        [.vector, .vector],
        .vector,
        .all,
        unorderedNaNs: .perLane,
        targets: TargetBodies(
            sve2_128: { element in
                sveConstantArithmetic("+", blocking: .both([.minusZero]), for: element)
            },
            sve2_128Splat: { element in sveSplatBinary("add", .arithmetic, for: element) }
        )
    ) { element in
        binaryArithmetic("+", for: element)
    },
    Op(
        "subtracting",
        "Sub",
        [.vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            sve2_128: { element in
                sveConstantArithmetic(
                    "-",
                    blocking: SveBlockedLanes(
                        first: [.minusZero, .notANumber],
                        second: [.zero, .notANumber]
                    ),
                    for: element
                )
            },
            sve2_128Splat: { element in
                sveSplatBinary("sub", .arithmetic, commutative: false, for: element)
            }
        )
    ) { element in
        binaryArithmetic("-", for: element)
    },
    Op(
        "multiplying",
        "Mul",
        [.vector, .vector],
        .vector,
        .all(bits: [16, 32, 64]),
        unorderedNaNs: .perLane,
        targets: TargetBodies(
            neon: { element in isInteger64(element) ? neonMultiplying64(for: element) : nil },
            sve2_128: { element in
                isInteger64(element)
                    ? sveBinary("mul", for: element)
                    : sveConstantArithmetic("*", blocking: .both([.one, .minusOne]), for: element)
            },
            sve2_128Splat: { element in sveSplatBinary("mul", .signed, for: element) },
            avx2: { element in isInteger64(element) ? x86Multiplying64(for: element) : nil },
            sse4: { element in
                if isInteger32(element) { return binaryArithmetic("*", for: element) }
                return isInteger64(element) ? x86Multiplying64(for: element) : nil
            },
            sse2: { element in
                if isInteger32(element) { return x86Multiplying32(for: element) }
                return isInteger64(element) ? x86Multiplying64(for: element) : nil
            }
        )
    ) { element in
        binaryArithmetic("*", for: element)
    },
    Op(
        "dividing",
        "Div",
        [.vector, .vector],
        .vector,
        .float,
        targets: TargetBodies(
            neon: { element in vectorResult("a / b", for: element) },
            sve2_128: { element in
                sveConstantArithmetic(
                    "/",
                    blocking: SveBlockedLanes(
                        first: [.notANumber],
                        second: [.notANumber, .one, .minusOne]
                    ),
                    for: element
                )
            },
            avx3: { element in vectorResult("a / b", for: element) },
            avx2: { element in vectorResult("a / b", for: element) },
            sse2: { element in vectorResult("a / b", for: element) }
        )
    ) { element in
        let vector = element.cVector
        let unsigned = element.cUnsignedVector
        let lanes = element.laneCount
        let signBit = "0x\(String(UInt64(1) << UInt64(element.bits - 1), radix: 16))"
        let infinityBits = unsignedBits("infinity", of: element)
        let divisor = bitSelect("zeroDenominator", "ones", "b", of: element)
        let signedInfinity = fromUnsignedBits("\(infinityBits) | signs", of: element)
        let zeroQuotient = bitSelect(
            "zeroOrNaNNumerator",
            "indeterminate",
            "signedInfinity",
            of: element
        )
        let result = bitSelect("zeroDenominator", "zeroQuotient", "quotient", of: element)
        return """
            const \(vector) zero = \(compoundLiteral(vector, ["0"]));
            const \(vector) ones = \(splat("1", as: vector, lanes: lanes));
            const \(vector) infinity = \(splat(infinity(of: element), as: vector, lanes: lanes));
            const \(unsigned) signBits = \(splat(signBit, as: unsigned, lanes: lanes));
            const \(unsigned) zeroDenominator = (\(unsigned))(b == zero);
            const \(unsigned) zeroOrNaNNumerator = (\(unsigned))((a == zero) | (a != a));
            const \(vector) quotient = a / \(divisor);
            const \(vector) indeterminate = a + (infinity * zero);
            const \(unsigned) signs = ((\(unsigned))a ^ (\(unsigned))b) & signBits;
            const \(vector) signedInfinity = \(signedInfinity);
            const \(vector) zeroQuotient = \(zeroQuotient);
            \(vectorResult(result, for: element))
            """
    },
    Op(
        "minimum",
        "Min",
        [.vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            neon: { element in neonExtremum("min", for: element) },
            sve2_128: { element in sveExtremum("min", blocking: .minusInfinity, for: element) },
            sve2_128Splat: { element in
                sveSplatBinary("min", sveExtremumImmediate(for: element), for: element)
            },
            avx3: { element in x86MinMax(.minimum, level: .avx3, for: element) },
            avx2: { element in x86MinMax(.minimum, level: .avx2, for: element) },
            sse4: { element in x86MinMax(.minimum, level: .sse4, for: element) },
            sse2: { element in x86MinMax(.minimum, level: .sse2, for: element) }
        ),
        outOfLineOnSVE: .float
    ) { element in
        elementwiseExtremum("min", comparing: "<", for: element)
    },
    Op(
        "maximum",
        "Max",
        [.vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            neon: { element in neonExtremum("max", for: element) },
            sve2_128: { element in sveExtremum("max", blocking: .infinity, for: element) },
            sve2_128Splat: { element in
                sveSplatBinary("max", sveExtremumImmediate(for: element), for: element)
            },
            avx3: { element in x86MinMax(.maximum, level: .avx3, for: element) },
            avx2: { element in x86MinMax(.maximum, level: .avx2, for: element) },
            sse4: { element in x86MinMax(.maximum, level: .sse4, for: element) },
            sse2: { element in x86MinMax(.maximum, level: .sse2, for: element) }
        ),
        outOfLineOnSVE: .float
    ) { element in
        elementwiseExtremum("max", comparing: ">", for: element)
    },
    Op("negated", "Neg", [.vector], .vector, .signedOrFloat) { element in
        guard element.category == .signedInteger else { return vectorResult("-a", for: element) }
        let zero = compoundLiteral(element.cUnsignedVector, ["0"])
        let difference = "(\(element.cVector))(\(zero) - (\(element.cUnsignedVector))a)"
        return vectorResult(difference, for: element)
    },
    Op(
        "magnitude",
        "Abs",
        [.vector],
        .vector,
        .signedOrFloat,
        targets: TargetBodies(
            sse4: { element in x86Magnitude(level: .sse4, for: element) },
            ssse3: { element in x86Magnitude(level: .ssse3, for: element) },
            sse2: { element in x86Magnitude(level: .sse2, for: element) }
        )
    ) { element in
        portableMagnitude(for: element)
    },
    Op("squareRoot", "Sqrt", [.vector], .vector, .float) { element in
        vectorResult("__builtin_elementwise_sqrt(a)", for: element)
    },
    Op(
        "multiplyAdding",
        "MulAdd",
        [.vector, .vector, .vector],
        .vector,
        .float,
        unorderedNaNs: .multiplyAdd,
        targets: TargetBodies(
            neon: { element in vectorResult("__builtin_elementwise_fma(a, b, c)", for: element) },
            sve2_128: { element in sveMultiplyAdding(for: element) },
            avx3: { element in vectorResult("__builtin_elementwise_fma(a, b, c)", for: element) },
            avx2: { element in
                """
                #if defined(HWY_DISABLE_BMI2_FMA)
                \(unfusedMultiplyAdding(for: element))
                #else
                \(vectorResult("__builtin_elementwise_fma(a, b, c)", for: element))
                #endif
                """
            }
        )
    ) { element in
        unfusedMultiplyAdding(for: element)
    },
    Op(
        "saturatingAdding",
        "SaturatedAdd",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16]),
        targets: TargetBodies(
            sve2_128Splat: { element in
                sveSplatBinary("qadd", .arithmetic, predicated: false, for: element)
            }
        )
    ) { element in
        vectorResult("__builtin_elementwise_add_sat(a, b)", for: element)
    },
    Op(
        "saturatingSubtracting",
        "SaturatedSub",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16]),
        targets: TargetBodies(
            neon: { element in neonSaturatingSubtraction(for: element) },
            sve2_128Splat: { element in
                sveSplatBinary(
                    "qsub",
                    .arithmetic,
                    commutative: false,
                    splattingFirst: false,
                    predicated: false,
                    for: element
                )
            }
        )
    ) { element in
        vectorResult("__builtin_elementwise_sub_sat(a, b)", for: element)
    },
    Op(
        "roundedAverage",
        "AverageRound",
        [.vector, .vector],
        .vector,
        .unsigned(bits: [8, 16]),
        targets: TargetBodies(
            neon: { element in neonRoundedAverage(for: element) },
            avx3: { element in x86RoundedAverage(for: element) },
            avx2: { element in x86RoundedAverage(for: element) },
            sse2: { element in x86RoundedAverage(for: element) }
        )
    ) { element in
        vectorResult("(a | b) - ((a ^ b) >> 1)", for: element)
    },

    Op(
        "bitwiseAnd",
        "And",
        [.vector, .vector],
        .vector,
        .integer,
        targets: TargetBodies(sve2_128Splat: { element in sveBitwiseSplat("and", for: element) })
    ) { element in
        vectorResult("a & b", for: element)
    },
    Op(
        "bitwiseOr",
        "Or",
        [.vector, .vector],
        .vector,
        .integer,
        targets: TargetBodies(sve2_128Splat: { element in sveBitwiseSplat("orr", for: element) })
    ) { element in
        vectorResult("a | b", for: element)
    },
    Op(
        "bitwiseXor",
        "Xor",
        [.vector, .vector],
        .vector,
        .integer,
        targets: TargetBodies(sve2_128Splat: { element in sveBitwiseSplat("eor", for: element) })
    ) { element in
        vectorResult("a ^ b", for: element)
    },
    Op("bitwiseNot", "Not", [.vector], .vector, .integer) { element in
        vectorResult("~a", for: element)
    },
    Op(
        "bitwiseAndNot",
        "AndNot",
        [.vector, .vector],
        .vector,
        .integer,
        targets: TargetBodies(
            sve2_128Splat: { element in
                sveBitwiseSplat("bic", operands: ("b", "a"), commutative: false, for: element)
            }
        )
    ) { element in
        vectorResult("~a & b", for: element)
    },
    Op(
        "bitwiseAndXor",
        "AndXor",
        [.vector, .vector, .vector],
        .vector,
        .integer,
        targets: TargetBodies(
            sve2_128: { element in sveAndXor(for: element) },
            avx3: { element in x86Avx3AndXor(for: element) }
        )
    ) { element in
        vectorResult("a & (b ^ c)", for: element)
    },

    Op(
        "shiftedLeft",
        "ShiftLeftSame",
        [.vector, .shiftAmount],
        .vector,
        .integer,
        targets: TargetBodies(
            neon: { element in neonShift(negated: false, for: element) },
            sve2_128: { element in sveShift("lsl", for: element) },
            avx3: { element in x86ShiftedLeft(for: element) },
            avx2: { element in x86ShiftedLeft(for: element) },
            sse2: { element in x86ShiftedLeft(for: element) }
        )
    ) { element in
        shiftedWithinWidth("<<", for: element)
    },
    Op(
        "shiftedRight",
        "ShiftRightSame",
        [.vector, .shiftAmount],
        .vector,
        .integer,
        targets: TargetBodies(
            neon: { element in neonShift(negated: true, for: element) },
            sve2_128: { element in
                sveShift(element.category == .signedInteger ? "asr" : "lsr", for: element)
            },
            avx3: { element in x86ShiftedRight(level: .avx3, for: element) },
            avx2: { element in x86ShiftedRight(level: .avx2, for: element) },
            sse4: { element in x86ShiftedRight(level: .sse4, for: element) },
            sse2: { element in x86ShiftedRight(level: .sse2, for: element) }
        )
    ) { element in
        guard element.category == .unsignedInteger else {
            return """
                bits = (unsigned)bits < \(element.bits) ? bits : \(element.bits - 1);
                \(vectorResult("a >> bits", for: element))
                """
        }
        return shiftedWithinWidth(">>", for: element)
    },

    Op("equalTo", "Eq", [.vector, .vector], .mask, .all) { element in
        maskResult("(\(element.cMask))(a == b)", for: element)
    },
    Op("notEqualTo", "Ne", [.vector, .vector], .mask, .all) { element in
        maskResult("(\(element.cMask))(a != b)", for: element)
    },
    Op(
        "lessThan",
        "Lt",
        [.vector, .vector],
        .mask,
        .all,
        targets: TargetBodies(
            sve2_128Splat: { element in
                sveComparisonSplat("cmplt", mirrored: "cmpgt", for: element)
            },
            avx3: { element in
                element.category == .unsignedInteger
                    ? maskResult("(\(element.cMask))(b > a)", for: element) : nil
            },
            avx2: { element in
                element.category == .unsignedInteger
                    ? x86UnsignedComparison("b", "a", native: true, for: element) : nil
            },
            sse4: { element in
                isSignedInteger64(element) || isUnsigned64(element)
                    ? vectorComparison("<", for: element) : nil
            },
            sse2: { element in
                if isSignedInteger64(element) {
                    return x86Int64Comparison("b", "a", for: element)
                }
                guard element.category == .unsignedInteger else { return nil }
                return x86UnsignedComparison("b", "a", for: element)
            }
        )
    ) { element in
        vectorComparison("<", for: element)
    },
    Op(
        "greaterThan",
        "Gt",
        [.vector, .vector],
        .mask,
        .all,
        targets: TargetBodies(
            sve2_128Splat: { element in
                sveComparisonSplat("cmpgt", mirrored: "cmplt", for: element)
            },
            avx2: { element in
                element.category == .unsignedInteger
                    ? x86UnsignedComparison("a", "b", native: true, for: element) : nil
            },
            sse4: { element in
                isSignedInteger64(element) || isUnsigned64(element)
                    ? vectorComparison(">", for: element) : nil
            },
            sse2: { element in
                if isSignedInteger64(element) {
                    return x86Int64Comparison("a", "b", for: element)
                }
                guard isUnsigned64(element) else { return nil }
                return x86UnsignedComparison("a", "b", for: element)
            }
        )
    ) { element in
        vectorComparison(">", for: element)
    },

    Op(
        "selecting",
        "IfThenElse",
        [.mask, .vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            avx3: { element in
                vectorResult(x86Avx3Selecting("mask", "a", "b", for: element), for: element)
            },
            avx2: { element in
                vectorResult(x86Selecting("mask", "a", "b", for: element), for: element)
            },
            sse4: { element in
                vectorResult(x86Selecting("mask", "a", "b", for: element), for: element)
            }
        )
    ) { element in
        vectorResult(bitSelect("mask", "a", "b", of: element), for: element)
    },
    Op(
        "selectingOrZero",
        "IfThenElseZero",
        [.mask, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            sve2_128Splat: { element in
                sveBitwiseSplat("and", operands: ("mask", "a"), splattingFirst: false, for: element)
            }
        )
    ) { element in
        let mask = "(\(element.cUnsignedVector))mask"
        let selected = fromUnsignedBits("\(mask) & \(unsignedBits("a", of: element))", of: element)
        return vectorResult(selected, for: element)
    },
    Op("zeroingSelected", "IfThenZeroElse", [.mask, .vector], .vector, .all) { element in
        let mask = "(\(element.cUnsignedVector))mask"
        let kept = fromUnsignedBits("~\(mask) & \(unsignedBits("a", of: element))", of: element)
        return vectorResult(kept, for: element)
    },
    Op(
        "bitwiseAnd",
        "MaskedAnd",
        [.whereMask, .vector, .vector],
        .vector,
        .integer,
        targets: maskedBitwiseTargets("&")
    ) { element in
        maskedBitwise("&", for: element)
    },
    Op(
        "bitwiseOr",
        "MaskedOr",
        [.whereMask, .vector, .vector],
        .vector,
        .integer,
        targets: maskedBitwiseTargets("|", neon: { element in maskedBitwise("|", for: element) })
    ) { element in
        commutedMaskedBitwise("|", for: element)
    },
    Op(
        "bitwiseXor",
        "MaskedXor",
        [.whereMask, .vector, .vector],
        .vector,
        .integer,
        targets: maskedBitwiseTargets("^", neon: { element in maskedBitwise("^", for: element) })
    ) { element in
        commutedMaskedBitwise("^", for: element)
    },
    Op(
        "bitwiseAnd",
        "MaskedAndOr",
        [.otherwiseVector, .whereMask, .vector, .vector],
        .vector,
        .integer,
        targets: maskedBitwiseOtherwiseTargets("&", operation: "bitwiseAnd")
    ) { element in
        maskedBitwiseOtherwise("&", for: element)
    },
    Op(
        "bitwiseOr",
        "MaskedOrOr",
        [.otherwiseVector, .whereMask, .vector, .vector],
        .vector,
        .integer,
        targets: maskedBitwiseOtherwiseTargets("|", operation: "bitwiseOr")
    ) { element in
        maskedBitwiseOtherwise("|", for: element)
    },
    Op(
        "bitwiseXor",
        "MaskedXorOr",
        [.otherwiseVector, .whereMask, .vector, .vector],
        .vector,
        .integer,
        targets: maskedBitwiseOtherwiseTargets("^", operation: "bitwiseXor")
    ) { element in
        maskedBitwiseOtherwise("^", for: element)
    },
    Op(
        "multiplyAddingLow52Bits",
        "MulAdd52Lo",
        [.vector, .vector, .vector],
        .vector,
        .unsigned(bits: [64]),
        targets: TargetBodies(
            sve2_128: { element in sveMultiplyAddingLow52Bits(for: element) },
            avx3dl: { element in x86MultiplyAdding52Bits(high: false, for: element) }
        )
    ) { element in
        multiplyAddingLow52Bits(for: element)
    },
    Op(
        "multiplyAddingHigh52Bits",
        "MulAdd52Hi",
        [.vector, .vector, .vector],
        .vector,
        .unsigned(bits: [64]),
        targets: TargetBodies(
            neon: { element in multiplyAddingHigh52BitsHalves(flippingSigns: false, for: element) },
            sve2_128: { element in sveMultiplyAddingHigh52Bits(for: element) },
            avx3dl: { element in x86MultiplyAdding52Bits(high: true, for: element) },
            avx3: { element in multiplyAddingHigh52BitsHalves(flippingSigns: false, for: element) },
            avx2: { element in multiplyAddingHigh52BitsHalves(flippingSigns: true, for: element) },
            sse4: { element in multiplyAddingHigh52BitsHalves(flippingSigns: true, for: element) },
            sse2: { element in multiplyAddingHigh52BitsHalves(flippingSigns: false, for: element) }
        )
    ) { element in
        multiplyAddingHigh52BitsWhole(for: element)
    },
    Op(
        "firstLanes",
        "FirstN",
        [.tag, .count],
        .mask,
        .all,
        constantArgument: ConstantArgument(name: "count", cast: "(uint32_t)"),
        targets: TargetBodies(
            neon: { element in signedFirstLanes(for: element) },
            sve2_128: { element in sveFirstLanes(for: element) },
            avx3: { element in x86Avx3FirstLanes(for: element) },
            avx2: { element in signedFirstLanes(for: element) },
            sse4: { element in signedFirstLanes(for: element) },
            sse2: { element in
                element.bits == 64
                    ? x86Int64FirstLanes(for: element) : signedFirstLanes(for: element)
            }
        )
    ) { element in
        let lanes = element.laneCount
        let offsets = iota(as: element.cUnsignedVector, lanes: lanes)
        let limit = splat("n", as: element.cUnsignedVector, lanes: lanes)
        let count = element.bits == 64 ? "count" : clampedCount(to: lanes)
        return """
            const \(element.cUnsignedLane) n = (\(element.cUnsignedLane))\(count);
            \(maskResult("(\(element.cMask))(\(offsets) < \(limit))", for: element))
            """
    },
    Op(
        "allTrue",
        "AllTrue",
        [.tag, .mask],
        .boolean,
        .all,
        targets: TargetBodies(
            neon: { _ in "\(neonNibbles)\nreturn nibbles == ~0ull;" },
            avx3: { element in x86AllTrue(for: element) },
            avx2: { element in x86AllTrue(for: element) },
            sse2: { element in x86AllTrue(for: element) }
        )
    ) { element in
        """
        \(element.cMaskLane) andSum = -1;
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          andSum &= mask[i];
        }
        return andSum == -1;
        """
    },
    Op(
        "allFalse",
        "AllFalse",
        [.tag, .mask],
        .boolean,
        .all,
        targets: TargetBodies(
            neon: { _ in "\(neonNibbles)\nreturn nibbles == 0;" },
            sve2_128: { element in sveAllFalse(for: element) },
            avx3: { element in "return \(x86MaskBits(for: element)) == 0;" },
            avx2: { element in "return \(x86MaskBits(for: element)) == 0;" },
            sse2: { element in "return \(x86MaskBits(for: element)) == 0;" }
        )
    ) { element in
        """
        \(element.cMaskLane) orSum = 0;
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          orSum |= mask[i];
        }
        return orSum == 0;
        """
    },
    Op(
        "trueCount",
        "CountTrue",
        [.tag, .mask],
        .count,
        .all,
        targets: TargetBodies(
            neon: { element in
                """
                \(element.cMask) raw = mask;
                __asm__("" : "+w"(raw));
                return (size_t)-(int64_t)__builtin_reduce_add(raw);
                """
            },
            avx3: { element in x86TrueCount(for: element) },
            avx2: { element in x86TrueCount(for: element) },
            sse2: { element in x86TrueCount(for: element) }
        )
    ) { _ in
        "return (size_t)-__builtin_reduce_add(mask);"
    },
    Op(
        "firstTrueIndex",
        "FindFirstTrue",
        [.tag, .mask],
        .index,
        .all,
        targets: TargetBodies(
            neon: { element in neonFirstTrueIndex(for: element) },
            avx3: { element in x86FirstTrueIndex(for: element) },
            avx2: { element in x86FirstTrueIndex(for: element) },
            sse2: { element in x86FirstTrueIndex(for: element) }
        )
    ) { element in
        let checks = (0..<element.laneCount).map { lane in
            "if (mask[\(lane)]) {\n  return \(lane);\n}"
        }
        return """
            \(checks.joined(separator: "\n"))
            return -1;
            """
    },

    Op(
        "sum",
        "ReduceSum",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        unorderedNaNs: .acrossLanes,
        targets: TargetBodies(
            neon: { element in neonReduction("vaddvq", for: element) ?? builtinReduction("add") },
            avx3: { element in x86Reduction(.sum, level: .avx3, for: element) },
            avx2: { element in x86Reduction(.sum, level: .avx2, for: element) },
            sse4: { element in x86Reduction(.sum, level: .sse4, for: element) },
            ssse3: { element in x86Reduction(.sum, level: .ssse3, for: element) },
            sse2: { element in x86Reduction(.sum, level: .sse2, for: element) }
        ),
        helpers: x86CombiningHelpers(.sum)
    ) { element in
        reducedSum(for: element)
    },
    Op(
        "smallest",
        "ReduceMin",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        constantArgument: ConstantArgument(name: "a", applies: isInteger64, vector: true),
        targets: TargetBodies(
            neon: { element in
                neonReduction("vminvq", for: element)
                    ?? neonPairExtremum(comparing: "<", for: element) ?? builtinReduction("min")
            },
            sve2_128: { element in
                neonReduction("vminnmvq", for: element) ?? sveReduction("minv", for: element)
            },
            avx3: { element in x86Reduction(.minimum, level: .avx3, for: element) },
            avx2: { element in x86Reduction(.minimum, level: .avx2, for: element) },
            sse4: { element in x86Reduction(.minimum, level: .sse4, for: element) },
            ssse3: { element in x86Reduction(.minimum, level: .ssse3, for: element) },
            sse2: { element in x86Reduction(.minimum, level: .sse2, for: element) }
        ),
        helpers: x86CombiningHelpers(.minimum)
    ) { element in
        reducedExtremum(comparing: "<", from: highestValue(of: element), for: element)
    },
    Op(
        "smallestOrNaN",
        "ReduceMinOrNaN",
        [.tag, .vector],
        .lane,
        .float,
        targets: TargetBodies(
            neon: { element in neonReduction("vminvq", for: element) },
            sve2_128: { element in neonReducedExtremumOrNaN("vminvq", for: element) },
            avx3: { element in
                reducedExtremumOrNaN("smallest", isNaN: x86Avx3IsNaN(for: element), for: element)
            },
            sse2: { element in
                reducedExtremumOrNaN("smallest", isNaN: x86IsNaN(for: element), for: element)
            }
        )
    ) { element in
        reducedExtremumOrNaN("smallest", isNaN: "(\(element.cMask))(a != a)", for: element)
    },
    Op(
        "largest",
        "ReduceMax",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        constantArgument: ConstantArgument(name: "a", applies: isInteger64, vector: true),
        targets: TargetBodies(
            neon: { element in
                neonReduction("vmaxvq", for: element)
                    ?? neonPairExtremum(comparing: ">", for: element) ?? builtinReduction("max")
            },
            sve2_128: { element in
                neonReduction("vmaxnmvq", for: element) ?? sveReduction("maxv", for: element)
            },
            avx3: { element in x86Reduction(.maximum, level: .avx3, for: element) },
            avx2: { element in x86Reduction(.maximum, level: .avx2, for: element) },
            sse4: { element in x86Reduction(.maximum, level: .sse4, for: element) },
            ssse3: { element in x86Reduction(.maximum, level: .ssse3, for: element) },
            sse2: { element in x86Reduction(.maximum, level: .sse2, for: element) }
        ),
        helpers: x86CombiningHelpers(.maximum)
    ) { element in
        reducedExtremum(comparing: ">", from: lowestValue(of: element), for: element)
    },
    Op(
        "largestOrNaN",
        "ReduceMaxOrNaN",
        [.tag, .vector],
        .lane,
        .float,
        targets: TargetBodies(
            neon: { element in neonReduction("vmaxvq", for: element) },
            sve2_128: { element in neonReducedExtremumOrNaN("vmaxvq", for: element) },
            avx3: { element in
                reducedExtremumOrNaN("largest", isNaN: x86Avx3IsNaN(for: element), for: element)
            },
            sse2: { element in
                reducedExtremumOrNaN("largest", isNaN: x86IsNaN(for: element), for: element)
            }
        )
    ) { element in
        reducedExtremumOrNaN("largest", isNaN: "(\(element.cMask))(a != a)", for: element)
    },
    Op("firstLane", "GetLane", [.vector], .lane, .all) { _ in
        "return a[0];"
    },

    Op(
        "reversed",
        "Reverse",
        [.tag, .vector],
        .vector,
        .all,
        constantArgument: ConstantArgument(name: "a", vector: true),
        targets: TargetBodies(
            sve2_128: { element in sveReversed(for: element) },
            ssse3: { element in element.bits == 8 ? portableReverse(for: element) : nil },
            sse2: { element in x86ReversedBytes(for: element) }
        )
    ) { element in
        portableReverse(for: element)
    },
    Op(
        "slideUpLanes",
        "SlideUpLanes",
        [.tag, .vector, .laneAmount],
        .vector,
        .all,
        constantArgument: ConstantArgument(name: "lanes"),
        targets: slideTargets(.up)
    ) { element in
        portableSlide(.up, for: element)
    },
    Op(
        "slideUpLanes",
        "SlideUpLanesOr",
        [.fillVector, .tag, .vector, .laneAmount],
        .vector,
        .all,
        constantArgument: ConstantArgument(name: "lanes"),
        targets: slideFillingTargets(.up),
        helpers: TargetBodies(sse2: { element in x86SlideLanes(.up, for: element) })
    ) { element in
        slideFilling(.up, sliding: slideLanesName(.up, for: element), for: element)
    },
    Op(
        "slideDownLanes",
        "SlideDownLanes",
        [.tag, .vector, .laneAmount],
        .vector,
        .all,
        targets: slideTargets(.down)
    ) { element in
        portableSlide(.down, for: element)
    },
    Op(
        "slideDownLanes",
        "SlideDownLanesOr",
        [.fillVector, .tag, .vector, .laneAmount],
        .vector,
        .all,
        targets: slideFillingTargets(.down),
        helpers: TargetBodies(sse2: { element in x86SlideLanes(.down, for: element) })
    ) { element in
        slideFilling(.down, sliding: slideLanesName(.down, for: element), for: element)
    },
    Op(
        "slide1Up",
        "Slide1Up",
        [.tag, .vector],
        .vector,
        .all,
        targets: slide1Targets(.up)
    ) { element in
        portableSlide1(.up, for: element)
    },
    Op(
        "slide1Up",
        "Slide1UpOr",
        [.fillLane, .tag, .vector],
        .vector,
        .all,
        targets: slide1FillingTargets(.up)
    ) { element in
        slide1Filling(.up, for: element)
    },
    Op(
        "slide1Down",
        "Slide1Down",
        [.tag, .vector],
        .vector,
        .all,
        targets: slide1Targets(.down)
    ) { element in
        portableSlide1(.down, for: element)
    },
    Op(
        "slide1Down",
        "Slide1DownOr",
        [.fillLane, .tag, .vector],
        .vector,
        .all,
        targets: slide1FillingTargets(.down)
    ) { element in
        slide1Filling(.down, for: element)
    },
    Op(
        "tableLookupBytes",
        "TableLookupBytes",
        [.vector, .indices],
        .vector,
        .integer(bits: [8]),
        indexContract: .bytes,
        targets: tableLookupBytesTargets(zeroing: false)
    ) { element in
        portableTableLookupBytes(for: element)
    },
    Op(
        "tableLookupBytesOrZero",
        "TableLookupBytesOr0",
        [.vector, .indices],
        .vector,
        .integer(bits: [8]),
        indexContract: .zeroingBytes,
        targets: tableLookupBytesTargets(zeroing: true)
    ) { element in
        portableTableLookupBytes(for: element)
    },
    Op(
        "tableLookupLanes",
        "TableLookupLanes",
        [.vector, .laneIndices],
        .vector,
        .all,
        indexContract: .lanes,
        targets: TargetBodies(
            neon: { element in neonTableLookupLanes(for: element) },
            sve2_128: { element in sveTableLookupLanes(for: element) },
            avx3dl: { element in x86TableLookupLanes(level: .avx3dl, for: element) },
            avx3: { element in x86TableLookupLanes(level: .avx3, for: element) },
            avx2: { element in x86TableLookupLanes(level: .avx2, for: element) },
            sse4: { element in x86TableLookupLanes(level: .sse4, for: element) },
            ssse3: { element in x86TableLookupLanes(level: .ssse3, for: element) },
            sse2: { element in x86TableLookupLanes(level: .sse2, for: element) }
        )
    ) { element in
        portableTableLookupLanes(for: element)
    },
    Op(
        "twoTablesLookupLanes",
        "TwoTablesLookupLanes",
        [.tag, .vector, .vector, .laneIndices],
        .vector,
        .all,
        indexContract: .lanesOfTwoTables,
        targets: TargetBodies(
            neon: { element in neonTwoTablesLookupLanes(for: element) },
            sve2_128: { element in sveTwoTablesLookupLanes(for: element) },
            avx3dl: { element in x86TwoTablesLookupLanes(level: .avx3dl, for: element) },
            avx3: { element in x86TwoTablesLookupLanes(level: .avx3, for: element) },
            avx2: { element in x86TwoTablesLookupLanes(level: .avx2, for: element) },
            sse4: { element in x86TwoTablesLookupLanes(level: .sse4, for: element) },
            ssse3: { element in x86TwoTablesLookupLanes(level: .ssse3, for: element) },
            sse2: { element in x86TwoTablesLookupLanes(level: .sse2, for: element) }
        )
    ) { element in
        portableTwoTablesLookupLanes(for: element)
    },

    Op(
        "loadInterleaved2",
        "LoadInterleaved2",
        [.tag, .constLanePointer, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(2),
        targets: TargetBodies(
            neon: { element in shuffleLoadInterleaved(channels: 2, for: element) },
            avx3dl: { element in x86Avx3LoadInterleaved2Body(level: .avx3dl, for: element) },
            avx3: { element in x86Avx3LoadInterleaved2Body(level: .avx3, for: element) },
            avx2: { element in x86Avx2LoadInterleaved2(for: element) },
            sse4: { element in
                element.bits <= 16 ? x86LoadInterleaved2(level: .sse4, for: element) : nil
            },
            ssse3: { element in
                element.bits <= 16 ? x86LoadInterleaved2(level: .ssse3, for: element) : nil
            },
            sse2: { element in
                element.bits <= 16
                    ? x86LoadInterleaved2(level: .sse2, for: element)
                    : shuffleLoadInterleaved(channels: 2, for: element)
            }
        )
    ) { element in
        loadInterleaved(channels: 2, for: element)
    },
    Op(
        "loadInterleaved3",
        "LoadInterleaved3",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(3),
        targets: TargetBodies(
            neon: { element in shuffleLoadInterleaved(channels: 3, for: element) },
            avx3: { element in x86Avx3LoadInterleaved3Body(for: element) },
            avx2: { element in x86Avx2LoadInterleaved3(for: element) },
            sse4: { element in
                element.bits >= 32
                    ? x86LoadInterleaved(
                        x86LoadInterleaved3Steps(level: .sse4, for: element),
                        channels: 3,
                        for: element
                    ) : nil
            },
            ssse3: { element in
                switch element.bits {
                case 8, 16: return x86LoadInterleaved3Lookups(level: .ssse3, for: element)
                case 64:
                    return x86LoadInterleaved(
                        x86LoadInterleaved3Steps(level: .ssse3, for: element),
                        channels: 3,
                        for: element
                    )
                default: return nil
                }
            },
            sse2: { element in
                switch element.bits {
                case 8, 16: return x86LoadInterleaved3Lookups(level: .sse2, for: element)
                case 32:
                    return x86LoadInterleaved(
                        x86LoadInterleaved3Steps(level: .sse2, for: element),
                        channels: 3,
                        for: element
                    )
                default: return shuffleLoadInterleaved(channels: 3, for: element)
                }
            }
        )
    ) { element in
        loadInterleaved(channels: 3, for: element)
    },
    Op(
        "loadInterleaved4",
        "LoadInterleaved4",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(4),
        targets: TargetBodies(
            neon: { element in shuffleLoadInterleaved(channels: 4, for: element) },
            avx3: { element in x86Avx3LoadInterleaved4(for: element) },
            avx2: { element in
                x86Avx2LoadInterleaved(
                    x86Shuffles(x86LoadInterleaved4Steps(for: element), for: element),
                    channels: 4,
                    for: element
                )
            },
            sse2: { element in
                x86LoadInterleaved(
                    x86LoadInterleaved4Steps(for: element),
                    channels: 4,
                    for: element
                )
            }
        )
    ) { element in
        loadInterleaved(channels: 4, for: element)
    },
    Op(
        "storeInterleaved2",
        "StoreInterleaved2",
        [.vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(2),
        targets: TargetBodies(
            neon: { element in shuffleStoreInterleaved(channels: 2, for: element) },
            avx3dl: { element in x86Avx3StoreInterleaved2Body(level: .avx3dl, for: element) },
            avx3: { element in x86Avx3StoreInterleaved2Body(level: .avx3, for: element) },
            avx2: { element in x86Avx2StoreInterleaved2(for: element) },
            sse2: { element in
                x86StoreInterleaved(
                    x86StoreInterleaved2Steps(for: element),
                    channels: 2,
                    for: element
                )
            }
        )
    ) { element in
        storeInterleaved(channels: 2, for: element)
    },
    Op(
        "storeInterleaved3",
        "StoreInterleaved3",
        [.vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(3),
        targets: TargetBodies(
            neon: { element in shuffleStoreInterleaved(channels: 3, for: element) },
            avx3: { element in x86Avx3StoreInterleaved3Body(for: element) },
            avx2: { element in x86Avx2StoreInterleaved3(for: element) },
            sse4: { element in
                element.bits >= 32
                    ? x86StoreInterleaved(
                        x86StoreInterleaved3Steps(level: .sse4, for: element),
                        channels: 3,
                        for: element
                    ) : nil
            },
            ssse3: { element in
                element.bits <= 16
                    ? x86StoreInterleaved3Lookups(level: .ssse3, for: element) : nil
            },
            sse2: { element in
                element.bits <= 16
                    ? x86StoreInterleaved3Lookups(level: .sse2, for: element)
                    : x86StoreInterleaved(
                        x86StoreInterleaved3Steps(level: .sse2, for: element),
                        channels: 3,
                        for: element
                    )
            }
        )
    ) { element in
        storeInterleaved(channels: 3, for: element)
    },
    Op(
        "storeInterleaved4",
        "StoreInterleaved4",
        [.vector, .vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(4),
        targets: TargetBodies(
            neon: { element in shuffleStoreInterleaved(channels: 4, for: element) },
            avx3: { element in x86Avx3StoreInterleaved4Body(for: element) },
            avx2: { element in x86Avx2StoreInterleaved4(for: element) },
            sse2: { element in
                x86StoreInterleaved(
                    x86StoreInterleaved4Steps(for: element),
                    channels: 4,
                    for: element
                )
            }
        )
    ) { element in
        storeInterleaved(channels: 4, for: element)
    },
]

let ops = basicOps + lookupSizes.map(lookupOp)

// A widening load reads lanes of a narrower element type and promotes each of them to the
// element type of the vector it returns. It is two Highway ops rather than one, and its pointer
// is not a `Lane` pointer, so it does not fit `Op` and is generated on its own below.
struct WideningOp {
    let swiftName: String
    let highwayName: String
    let takesCount: Bool
    var targets = TargetBodies<WideningElements>()

    var span: SpanExtent { takesCount ? .first : .vectors(1) }
}

let wideningOps: [WideningOp] = [
    WideningOp(
        swiftName: "loadWidening",
        highwayName: "LoadU",
        takesCount: false,
        targets: TargetBodies(
            avx3: { pair in x86Avx3Widening(from: pair.narrow, to: pair.wide) },
            avx2: { pair in x86Widening(takesCount: false, from: pair.narrow, to: pair.wide) },
            sse2: { pair in x86Widening(takesCount: false, from: pair.narrow, to: pair.wide) }
        )
    ),
    WideningOp(
        swiftName: "loadFirstWidening",
        highwayName: "LoadN",
        takesCount: true,
        targets: TargetBodies(
            neon: { pair in neonLoadFirstWidening(from: pair.narrow, to: pair.wide) },
            sve2_128: { pair in sveLoadFirstWidening(from: pair.narrow, to: pair.wide) },
            avx3: { pair in x86Avx3LoadFirstWidening(from: pair.narrow, to: pair.wide) },
            avx2: { pair in x86Widening(takesCount: true, from: pair.narrow, to: pair.wide) },
            sse2: { pair in x86Widening(takesCount: true, from: pair.narrow, to: pair.wide) }
        )
    ),
]

/// The element types `element` can be widened from: every narrower one Highway promotes to it,
/// which is every narrower one of the same category.
func wideningSources(of element: Element) -> [Element] {
    elements.filter { $0.category == element.category && $0.bits < element.bits }
}

func wideningFunctionName(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    "\(op.swiftName)\(narrow.suffix)To\(wide.suffix)"
}

func snakeCased(_ name: String) -> String {
    name.replacingOccurrences(of: "NaN", with: "Nan")
        .map { $0.isUppercase ? "_\($0.lowercased())" : String($0) }.joined()
}

func cFunctionName(_ swiftName: String, _ element: Element) -> String {
    "cvectorization_ops_\(snakeCased(swiftName))_\(element.cSuffix)"
}

func referenceFunctionName(_ name: String, _ element: Element) -> String {
    "\(name)\(element.suffix)"
}

func cWideningFunctionName(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    "cvectorization_ops_\(snakeCased(op.swiftName))_\(narrow.cSuffix)_to_\(wide.cSuffix)"
}

let repeatingBlockName = "repeatingBlock"

/// The parameters of `repeatingBlock`, one per lane of a 128-bit block.
func repeatingBlockLanes(of element: Element) -> [String] {
    (0..<element.blockLaneCount).map { "v\($0)" }
}

struct Binding {
    let declaration: String
    let cDeclaration: String
    let argument: String
    let swiftLabel: String?
    let swiftName: String
    let swiftType: String
    let isInOut: Bool
}

func bindings(
    of op: Op,
    for element: Element,
    scope: String = "",
    checked: Bool = true
) -> [Binding] {
    var vectorNames = ["a", "b", "c", "d"].makeIterator()
    var outVectorIndex = 0
    var result: [Binding] = []

    for parameter in op.parameters {
        switch parameter {
        case .tag:
            result.append(
                Binding(
                    declaration: "",
                    cDeclaration: "",
                    argument: "\(element.tag)()",
                    swiftLabel: nil,
                    swiftName: "",
                    swiftType: "",
                    isInOut: false
                )
            )
        case .vector:
            let name = vectorNames.next() ?? "v"
            result.append(
                Binding(
                    declaration: "\(element.cRawVector) \(name)",
                    cDeclaration: "\(element.cRawVector) \(rawName(name))",
                    argument: referenceConversion("fromPort", name, for: element),
                    swiftLabel: "_",
                    swiftName: name,
                    swiftType: "\(scope)Vector",
                    isInOut: false
                )
            )
        case .indices:
            result.append(
                Binding(
                    declaration: "\(element.cRawVector) indices",
                    cDeclaration: "\(element.cRawVector) \(rawName("indices"))",
                    argument: referenceConversion("fromPort", "indices", for: element),
                    swiftLabel: checkedLabel("at", checked: checked),
                    swiftName: "indices",
                    swiftType: "\(scope)Vector",
                    isInOut: false
                )
            )
        case .laneIndices:
            let indexElement = laneIndexElement(of: element)
            let vector = referenceConversion("fromPort", "indices", for: indexElement)
            result.append(
                Binding(
                    declaration: "\(indexElement.cRawVector) indices",
                    cDeclaration: "\(indexElement.cRawVector) \(rawName("indices"))",
                    argument: "hn::IndicesFromVec(\(element.tag)(), \(vector))",
                    swiftLabel: checkedLabel("at", checked: checked),
                    swiftName: "indices",
                    swiftType: "\(scope)Indices",
                    isInOut: false
                )
            )
        case .lookupIndices:
            let indexElement = laneIndexElement(of: element)
            result.append(
                Binding(
                    declaration: "\(indexElement.cRawVector) indices",
                    cDeclaration: "\(indexElement.cRawVector) \(rawName("indices"))",
                    argument: referenceConversion("fromPort", "indices", for: indexElement),
                    swiftLabel: "at",
                    swiftName: "indices",
                    swiftType: "\(scope)Indices",
                    isInOut: false
                )
            )
        case .mask, .whereMask:
            result.append(
                Binding(
                    declaration: "\(element.cRawMask) mask",
                    cDeclaration: "\(element.cRawMask) \(rawName("mask"))",
                    argument: referenceConversion("maskFromPort", "mask", for: element),
                    swiftLabel: parameter.overloading?.label ?? "_",
                    swiftName: "mask",
                    swiftType: "\(scope)Mask",
                    isInOut: false
                )
            )
        case .lane:
            result.append(
                Binding(
                    declaration: "\(element.cType) value",
                    cDeclaration: "\(element.cType) value",
                    argument: "value",
                    swiftLabel: "_",
                    swiftName: "value",
                    swiftType: "\(scope)Lane",
                    isInOut: false
                )
            )
        case .constLanePointer:
            result.append(
                Binding(
                    declaration: "const \(element.cType)* from",
                    cDeclaration: "const \(element.cType)* from",
                    argument: "from",
                    swiftLabel: "from",
                    swiftName: "from",
                    swiftType: "UnsafePointer<\(scope)Lane>",
                    isInOut: false
                )
            )
        case .lanePointer:
            result.append(
                Binding(
                    declaration: "\(element.cType)* to",
                    cDeclaration: "\(element.cType)* to",
                    argument: "to",
                    swiftLabel: "to",
                    swiftName: "to",
                    swiftType: "UnsafeMutablePointer<\(scope)Lane>",
                    isInOut: false
                )
            )
        case .count:
            result.append(
                Binding(
                    declaration: "size_t count",
                    cDeclaration: "size_t count",
                    argument: "count",
                    swiftLabel: "count",
                    swiftName: "count",
                    swiftType: "Int",
                    isInOut: false
                )
            )
        case .shiftAmount:
            result.append(
                Binding(
                    declaration: "int bits",
                    cDeclaration: "int bits",
                    argument: "bits",
                    swiftLabel: "by",
                    swiftName: "bits",
                    swiftType: "Int",
                    isInOut: false
                )
            )
        case .laneAmount:
            result.append(
                Binding(
                    declaration: "size_t lanes",
                    cDeclaration: "size_t lanes",
                    argument: "lanes",
                    swiftLabel: checkedLabel("by", checked: checked),
                    swiftName: "lanes",
                    swiftType: "Int",
                    isInOut: false
                )
            )
        case .outVector:
            let name = "v\(outVectorIndex)"
            outVectorIndex += 1
            result.append(
                Binding(
                    declaration: "\(element.outVector)& \(name)",
                    cDeclaration: "void* \(rawName(name))",
                    argument: "inPlace<\(element.vector)>(\(name))",
                    swiftLabel: "_",
                    swiftName: name,
                    swiftType: "\(scope)Vector",
                    isInOut: true
                )
            )
        case .fillVector:
            result.append(
                Binding(
                    declaration: "\(element.cRawVector) fill",
                    cDeclaration: "\(element.cRawVector) \(rawName("fill"))",
                    argument: referenceConversion("fromPort", "fill", for: element),
                    swiftLabel: parameter.overloading?.label,
                    swiftName: "fill",
                    swiftType: "\(scope)Vector",
                    isInOut: false
                )
            )
        case .fillLane:
            result.append(
                Binding(
                    declaration: "\(element.cType) fill",
                    cDeclaration: "\(element.cType) fill",
                    argument: "fill",
                    swiftLabel: parameter.overloading?.label,
                    swiftName: "fill",
                    swiftType: "\(scope)Lane",
                    isInOut: false
                )
            )
        case .otherwiseVector:
            result.append(
                Binding(
                    declaration: "\(element.cRawVector) otherwise",
                    cDeclaration: "\(element.cRawVector) \(rawName("otherwise"))",
                    argument: referenceConversion("fromPort", "otherwise", for: element),
                    swiftLabel: parameter.overloading?.label,
                    swiftName: "otherwise",
                    swiftType: "\(scope)Vector",
                    isInOut: false
                )
            )
        }
    }
    return result
}

func referenceConversion(
    _ conversion: String,
    _ expression: String,
    for element: Element
) -> String {
    "\(referenceFunctionName(conversion, element))(\(expression))"
}

func referenceToPort(
    _ call: String,
    returning returns: ReturnType,
    for element: Element
) -> String {
    switch returns {
    case .vector: return referenceConversion("toPort", call, for: element)
    case .mask: return referenceConversion("maskToPort", call, for: element)
    default: return call
    }
}

func referenceBody(
    calling call: String,
    returning returns: ReturnType,
    for element: Element
) -> String {
    guard returns != .void else { return "\(call);" }
    return "return \(referenceToPort(call, returning: returns, for: element));"
}

func referenceOutVectorBody(
    of op: Op,
    for element: Element,
    bindings parameterBindings: [Binding]
) -> String {
    var temporaryArguments: [String] = []
    var temporaries: [String] = []
    var bridgedStores: [String] = []
    var memoryStores: [String] = []
    for binding in parameterBindings {
        guard binding.isInOut else {
            temporaryArguments.append(binding.argument)
            continue
        }
        let temporary = "h\(temporaries.count)"
        let pointer = "reinterpret_cast<\(element.cType)*>(&\(binding.swiftName))"
        temporaryArguments.append(temporary)
        temporaries.append(temporary)
        let converted = referenceConversion("toPort", temporary, for: element)
        bridgedStores.append("\(binding.swiftName) = \(converted);")
        memoryStores.append("hn::StoreU(\(temporary), \(element.tag)(), \(pointer));")
    }
    let inPlaceArguments = parameterBindings.map(\.argument).joined(separator: ", ")
    let declaration = "\(element.vector) \(temporaries.joined(separator: ", "));"
    let call = "hn::\(op.highwayName)(\(temporaryArguments.joined(separator: ", ")));"
    func outOfPlace(_ stores: [String]) -> String {
        ([declaration, call] + stores).map { "  \($0)" }.joined(separator: "\n")
    }
    return """
        #if HWY_TARGET_IS_SVE
        \(outOfPlace(bridgedStores))
        #elif HWY_MAX_BYTES > 16
        \(outOfPlace(memoryStores))
        #else
          hn::\(op.highwayName)(\(inPlaceArguments));
        #endif
        """
}

func cReturnType(_ returns: ReturnType, _ element: Element) -> String {
    switch returns {
    case .vector: return element.cRawVector
    case .mask: return element.cRawMask
    case .lane: return element.cType
    case .count: return "size_t"
    case .index: return "intptr_t"
    case .boolean: return "bool"
    case .void: return "void"
    }
}

func swiftReturnType(_ returns: ReturnType, scope: String = "") -> String {
    switch returns {
    case .vector: return "\(scope)Vector"
    case .mask: return "\(scope)Mask"
    case .lane: return "\(scope)Lane"
    case .count, .index: return "Int"
    case .boolean: return "Bool"
    case .void: return "Void"
    }
}

func importedReturnType(_ returns: ReturnType, _ element: Element) -> String {
    switch returns {
    case .vector: return "\(element.namespace).Vector"
    case .mask: return "\(element.namespace).Mask"
    case .lane: return element.swiftType
    case .count, .index: return "Int"
    case .boolean: return "Bool"
    case .void: return "Void"
    }
}

let generationNotice = """
    // Generated by utils/GenerateVectorizationOps.swift. Do not edit.
    """

func unavailableSendableConformance(of type: String) -> String {
    """
    @available(*, unavailable)
    extension \(type): Sendable {}
    """
}

func neonBridgeType(of element: Element) -> String {
    let name =
        switch element.category {
        case .unsignedInteger: "uint"
        case .signedInteger: "int"
        case .float: "float"
        }
    return "\(name)\(element.bits)x\(element.blockLaneCount)_t"
}

func neonBridgeToSve(_ expression: String, of element: Element) -> String {
    let suffix = sveSuffix(of: element)
    return
        "svset_neonq_\(suffix)(svundef_\(suffix)(), (\(neonBridgeType(of: element)))\(expression))"
}

func neonBridgeFromSve(_ expression: String, of element: Element, as type: String) -> String {
    "(\(type))svget_neonq_\(sveSuffix(of: element))(\(expression))"
}

func bridgedPortConversions(of element: Element) -> String {
    let signed = signedElement(of: element)
    let signedTag = "const hn::RebindToSigned<\(element.tag)> di;"
    var output = ""
    output += "HWY_INLINE \(element.vector) \(referenceFunctionName("fromPort", element))"
    output +=
        "(\(element.cRawVector) v) { return \(neonBridgeToSve("v", of: element)); }\n"
    output += "HWY_INLINE \(element.cRawVector) \(referenceFunctionName("toPort", element))"
    output += "(\(element.vector) v) { return "
    output += "\(neonBridgeFromSve("v", of: element, as: element.cRawVector)); }\n"
    output += "HWY_INLINE \(element.mask) \(referenceFunctionName("maskFromPort", element))"
    output +=
        "(\(element.cRawMask) m) { return hn::MaskFromVec(hn::BitCast("
    output += "\(element.tag)(), \(neonBridgeToSve("m", of: signed)))); }\n"
    output += "HWY_INLINE \(element.cRawMask) \(referenceFunctionName("maskToPort", element))"
    output += "(\(element.mask) m) { \(signedTag) return "
    output += neonBridgeFromSve(
        "hn::BitCast(di, hn::VecFromMask(\(element.tag)(), m))",
        of: signed,
        as: element.cRawMask
    )
    output += "; }\n"
    return output
}

func memoryPortConversions(of element: Element) -> String {
    let signedTag = "const hn::RebindToSigned<\(element.tag)> di;"
    var output = ""
    output += "HWY_INLINE \(element.vector) \(referenceFunctionName("fromPort", element))"
    output +=
        "(\(element.cRawVector) v) { return hn::LoadU(\(element.tag)(), "
    output += "reinterpret_cast<const \(element.cType)*>(&v)); }\n"
    output += "HWY_INLINE \(element.cRawVector) \(referenceFunctionName("toPort", element))"
    output +=
        "(\(element.vector) v) { \(element.cRawVector) port; "
    output += "hn::StoreU(v, \(element.tag)(), reinterpret_cast<\(element.cType)*>(&port)); "
    output += "return port; }\n"
    output += "HWY_INLINE \(element.mask) \(referenceFunctionName("maskFromPort", element))"
    output +=
        "(\(element.cRawMask) m) { \(signedTag) return hn::MaskFromVec(hn::BitCast("
    output += "\(element.tag)(), hn::LoadU(di, "
    output += "reinterpret_cast<const \(element.cMaskLane)*>(&m)))); }\n"
    output += "HWY_INLINE \(element.cRawMask) \(referenceFunctionName("maskToPort", element))"
    output +=
        "(\(element.mask) m) { \(signedTag) \(element.cRawMask) port; "
    output += "hn::StoreU(hn::BitCast(di, hn::VecFromMask(\(element.tag)(), m)), di, "
    output += "reinterpret_cast<\(element.cMaskLane)*>(&port)); return port; }\n"
    return output
}

func portConversions(of element: Element) -> String {
    """
    #if HWY_TARGET_IS_SVE
    \(bridgedPortConversions(of: element))#else
    \(memoryPortConversions(of: element))#endif

    """
}

func generateReferenceHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_HIGHWAY_REFERENCE_H
        #define SWIFT_HIGHWAY_REFERENCE_H

        #include <stddef.h>
        #include <stdint.h>
        #include <new>
        #include "CVectorizationOps.h"

        #include "hwy/highway.h"
        #if HWY_TARGET_IS_SVE
        #include <arm_neon_sve_bridge.h>
        #endif

        namespace hwy {
        namespace HWY_NAMESPACE {
        struct ReferenceTarget {};
        }  // namespace HWY_NAMESPACE
        }  // namespace hwy

        namespace HighwayReference {
        namespace hn = hwy::HWY_NAMESPACE;

        /// Names the static target in the mangled name of a Swift function that takes it, which
        /// scripts/compare-codegen.sh reads the target from.
        using Target = hn::ReferenceTarget;

        /// Lets Highway write an out-parameter in place, so that its stores happen where the
        /// port's do, rather than all at once as a copy of a local would have them.
        template <typename Highway, typename Port>
        HWY_INLINE Highway& inPlace(Port& port) {
          static_assert(sizeof(Highway) == sizeof(Port), "the port's vector has Highway's size");
          static_assert(alignof(Highway) <= 16, "Swift aligns the port's vector to at most 16 bytes");
          return *new (&port) Highway;
        }

        /// The count a span form hands to an op that takes one. Highway's SVE2_128 ops truncate a
        /// count to 32 bits, so they get at most `lanes`, while the other targets take any.
        HWY_INLINE size_t spanCount(size_t count, size_t lanes) {
          return HWY_TARGET == HWY_SVE2_128 && count > lanes ? lanes : count;
        }

        /// Whether the static target only emulates vectors, in which case a caller is better off
        /// with its own scalar code.
        HWY_INLINE bool isEmulated() {
          return HWY_TARGET == HWY_SCALAR || HWY_TARGET == HWY_EMU128;
        }

        /// The name of the target the ops below were compiled for.
        HWY_INLINE const char* targetName() { return hwy::TargetName(HWY_TARGET); }

        /// Whether highway's debug assertions are on, which abort on indices that its lookups
        /// do not accept.
        HWY_INLINE bool hasDebugAssertions() { return HWY_IS_DEBUG_BUILD; }

        /// Highway's SVE ops overwrite one operand, so the compiler may swap a commutative op's
        /// operands to save a move, which decides whose NaN comes out when both are NaN. Out of
        /// line, the first operand is already in the register the op overwrites, which is the
        /// order Highway's call has.
        #if HWY_TARGET_IS_SVE
        #define SWIFT_HIGHWAY_REFERENCE_OPERAND_ORDERED inline HWY_NOINLINE
        #else
        #define SWIFT_HIGHWAY_REFERENCE_OPERAND_ORDERED HWY_INLINE
        #endif


        """

    var nothrow = ""
    for element in elements {
        output += "using \(element.tag) = hn::ScalableTag<\(element.cType)>;\n"
        output += "using \(element.vector) = hn::VFromD<\(element.tag)>;\n"
        output += "using \(element.mask) = hn::MFromD<\(element.tag)>;\n"
        output += "typedef \(element.cRawVector) \(element.outVector) "
        output += "__attribute__((aligned(16)));\n"
        output += "HWY_INLINE size_t \(referenceFunctionName("laneCount", element))()"
        output += " { return hn::Lanes(\(element.tag)()); }\n"
        nothrow += referenceNothrowWrapper(
            returning: "size_t",
            named: referenceFunctionName("laneCount", element),
            declarations: ""
        )
        for size in lookupSizes where size.applies.matches(element) {
            let name = canLookupName(size.lanes)
            output += "HWY_INLINE bool \(referenceFunctionName(name, element))()"
            output += " { return hn::CanLookup\(size.lanes)(\(element.tag)()); }\n"
        }
        output += portConversions(of: element)

        for op in ops where op.applies.matches(element) {
            let parameterBindings = bindings(of: op, for: element)
            let declarations =
                parameterBindings
                .filter { !$0.declaration.isEmpty }
                .map(\.declaration)
                .joined(separator: ", ")
            let arguments = parameterBindings.map(\.argument).joined(separator: ", ")
            let body = referenceBody(
                calling: "hn::\(op.highwayName)(\(arguments))",
                returning: op.returns,
                for: element
            )
            let specifier =
                op.outOfLineOnSVE?.matches(element) == true
                ? "SWIFT_HIGHWAY_REFERENCE_OPERAND_ORDERED" : "HWY_INLINE"
            output += "\(specifier) \(cReturnType(op.returns, element)) "
            output +=
                "\(referenceFunctionName(op.identifier, element))(\(declarations))"
            if parameterBindings.contains(where: \.isInOut) {
                let outVectorBody = referenceOutVectorBody(
                    of: op,
                    for: element,
                    bindings: parameterBindings
                )
                output += " {\n\(outVectorBody)\n}\n"
            } else {
                output += " { \(body) }\n"
            }
            nothrow += referenceNothrowWrapper(
                returning: cReturnType(op.returns, element),
                named: referenceFunctionName(op.identifier, element),
                declarations: declarations
            )
        }

        for op in wideningOps {
            for narrow in wideningSources(of: element) {
                let countDeclaration = op.takesCount ? ", size_t count" : ""
                let countArgument = op.takesCount ? ", count" : ""
                let narrowTag = "hn::Rebind<\(narrow.cType), \(element.tag)>()"
                let load = "hn::\(op.highwayName)(\(narrowTag), from\(countArgument))"
                let body = referenceBody(
                    calling: "hn::PromoteTo(\(element.tag)(), \(load))",
                    returning: .vector,
                    for: element
                )
                output += "HWY_INLINE \(cReturnType(.vector, element)) "
                output += "\(wideningFunctionName(op, from: narrow, to: element))"
                output +=
                    "(const \(narrow.cType)* from\(countDeclaration))"
                output += " { \(body) }\n"
                nothrow += referenceNothrowWrapper(
                    returning: cReturnType(.vector, element),
                    named: wideningFunctionName(op, from: narrow, to: element),
                    declarations: "const \(narrow.cType)* from\(countDeclaration)"
                )
            }
        }

        let blockLanes = repeatingBlockLanes(of: element)
        let blockArguments = blockLanes.joined(separator: ", ")
        let blockBody = referenceBody(
            calling: "hn::Dup128VecFromValues(\(element.tag)(), \(blockArguments))",
            returning: .vector,
            for: element
        )
        output += "HWY_INLINE \(cReturnType(.vector, element)) "
        output += "\(referenceFunctionName(repeatingBlockName, element))("
        output += blockLanes.map { "\(element.cType) \($0)" }.joined(separator: ", ")
        output += ") { \(blockBody) }\n"
        nothrow += referenceNothrowWrapper(
            returning: cReturnType(.vector, element),
            named: referenceFunctionName(repeatingBlockName, element),
            declarations: blockLanes.map { "\(element.cType) \($0)" }.joined(separator: ", ")
        )
        output += "\n"
    }

    output += """
        /// Swift calls a C++ function that might throw as an `invoke` with a landing pad, which makes
        /// LLVM schedule the code around the call differently from the code around the port's C
        /// functions. The codegen comparison calls these `noexcept` forwarders instead, which the
        /// tests do not: with them LLVM would no longer inline the ops into the tests' code.
        namespace Nothrow {
        HWY_INLINE size_t spanCount(size_t count, size_t lanes) noexcept {
          return ::HighwayReference::spanCount(count, lanes);
        }
        \(nothrow)}  // namespace Nothrow

        }  // namespace HighwayReference

        #endif

        """
    return output
}

func wideningBody(takesCount: Bool, from narrow: Element, to wide: Element) -> String {
    let lanes = wide.laneCount
    let bytes = lanes * narrow.bits / 8
    let declaration = takesCount ? zeroedVector(of: "narrow_vector") : "narrow_vector v;"
    let size =
        takesCount
        ? "\(clampedCount(to: lanes)) * sizeof(\(narrow.cType))"
        : "sizeof v"
    return """
        typedef \(narrow.cType) narrow_vector __attribute__((vector_size(\(bytes))));
        \(declaration)
        __builtin_memcpy(&v, from, \(size));
        \(wide.cVector) result;
        for (size_t i = 0; i < \(lanes); ++i) {
          result[i] = v[i];
        }
        \(vectorResult("result", for: wide))
        """
}

func repeatingBlockBody(of element: Element) -> String {
    let blocks = Array(repeating: repeatingBlockLanes(of: element), count: element.width / 16)
    return vectorResult(compoundLiteral(element.cVector, blocks.flatMap { $0 }), for: element)
}

typealias TargetBranch = (condition: String, body: String)

let neonCondition = "CVECTORIZATION_OPS_NEON"
let sve2_128Condition = "\(neonCondition) == \(ArmLevel.sve2_128.rawValue)"

func x86Condition(from first: X86Level, through last: X86Level) -> String {
    guard first != last else { return "CVECTORIZATION_OPS_X86 == \(first.rawValue)" }
    return
        "CVECTORIZATION_OPS_X86 >= \(first.rawValue) && CVECTORIZATION_OPS_X86 <= \(last.rawValue)"
}

func mergingIdenticalBodies(_ branches: [TargetBranch]) -> [TargetBranch] {
    var merged = branches
    guard let neon = merged.first, neon.condition == neonCondition,
        let index = merged.lastIndex(where: {
            $0.body == neon.body && $0.condition != neonCondition
        })
    else { return merged }
    merged[index].condition = "\(neonCondition) || (\(merged[index].condition))"
    merged.removeFirst()
    return merged
}

func x86Branches<Input: WidthScaled>(
    _ targets: TargetBodies<Input>,
    for input: Input,
    portable: ((Input) -> String)?
) -> [TargetBranch] {
    var ranges: [(first: X86Level, last: X86Level, body: String)] = []
    for level in supportedX86Levels {
        let scaled = input.at(width: level.width)
        let inherited = level.inherited.lazy.compactMap { targets.body(at: $0)?(scaled) }.first
        let widened = level.width > 16 ? portable?(scaled) : nil
        guard let body = inherited ?? widened else { continue }
        if let previous = ranges.last, previous.body == body,
            previous.last.rawValue + 1 == level.rawValue
        {
            ranges[ranges.count - 1].last = level
        } else {
            ranges.append((level, level, body))
        }
    }
    return ranges.reversed().map { range in
        (condition: x86Condition(from: range.first, through: range.last), body: range.body)
    }
}

func cBody<Input: WidthScaled>(
    _ targets: TargetBodies<Input>,
    for input: Input,
    portable: ((Input) -> String)?
) -> String {
    let fallback = portable?(input)
    let neonBody = targets.neon?(input)
    let splatBody = targets.sve2_128Splat?(input).map {
        [$0, neonBody ?? fallback].compactMap { $0 }.joined(separator: "\n")
    }
    let sve2 = (targets.sve2_128?(input) ?? splatBody).map {
        (condition: sve2_128Condition, body: $0)
    }
    let neon = neonBody.map { (condition: neonCondition, body: $0) }
    let specific = (neon.map { [$0] } ?? []) + x86Branches(targets, for: input, portable: portable)
    let branches =
        (sve2.map { [$0] } ?? []) + mergingIdenticalBodies(specific.filter { $0.body != fallback })
    guard !branches.isEmpty else { return fallback ?? "" }
    let chain = branches.enumerated().flatMap { index, branch in
        ["#\(index == 0 ? "if" : "elif") \(branch.condition)", branch.body]
            .filter { !$0.isEmpty }
    }
    let otherwise = fallback.map { ["#else", $0] } ?? []
    return (chain + otherwise + ["#endif"]).joined(separator: "\n")
}

func neonHelperName(of op: Op, for element: Element) -> String {
    cFunctionName("neon" + uppercasedFirst(op.identifier), element)
}

func constantArgumentOf(_ op: Op, for element: Element) -> ConstantArgument? {
    guard let constant = op.constantArgument, constant.applies(element),
        op.targets.sve2_128?(element) != nil
    else { return nil }
    return constant
}

func cBody(of op: Op, for element: Element) -> String {
    var targets = op.targets
    if let constant = constantArgumentOf(op, for: element), let sve = targets.sve2_128 {
        let arguments = bindings(of: op, for: element)
            .filter { !$0.cDeclaration.isEmpty }
            .map { String($0.cDeclaration.split(separator: " ").last ?? "") }
            .map { $0 == constant.name ? "\(constant.cast)\($0)" : $0 }
        let call = "\(neonHelperName(of: op, for: element))(\(arguments.joined(separator: ", ")))"
        let delegation = op.returns == .void ? "\(call);\n  return;" : "return \(call);"
        let known =
            constant.vector
            ? "\(cFunctionName("sveConstant", element))(\(constant.name))"
            : "__builtin_constant_p(\(constant.name))"
        let conditions = [known] + (constant.holds.map { [$0(element)] } ?? [])
        targets.sve2_128 = { element in
            sve(element).map { body in
                """
                if (\(conditions.joined(separator: " && "))) {
                  \(delegation)
                }
                \(body)
                """
            }
        }
    }
    return cBody(targets, for: element, portable: op.portable)
}

func cHelpers(of op: Op, for element: Element) -> String {
    var helpers = cBody(op.helpers, for: element, portable: nil)
    if constantArgumentOf(op, for: element) != nil {
        let parameters = bindings(of: op, for: element)
            .filter { !$0.cDeclaration.isEmpty }
            .map(\.cDeclaration)
        let function = cOpFunction(
            returns: op.returns,
            name: neonHelperName(of: op, for: element),
            parameters: parameters,
            prologue: cPrologue(of: op, for: element),
            body: op.targets.neon?(element) ?? op.portable(element),
            for: element
        )
        helpers += "\(helpers.isEmpty ? "" : "\n")#if \(sve2_128Condition)\n\(function)#endif"
    }
    return helpers.isEmpty ? "" : "\(helpers)\n"
}

func cBody(of op: WideningOp, from narrow: Element, to wide: Element) -> String {
    cBody(
        op.targets,
        for: WideningElements(narrow: narrow, wide: wide),
        portable: { pair in
            wideningBody(takesCount: op.takesCount, from: pair.narrow, to: pair.wide)
        }
    )
}

func x86Helpers() -> String {
    let i64 = x86Vector("i64")
    let asFloats = [32, 64].map { bits in
        let float = x86Vector("f\(bits)")
        return cFunction(
            returns: float,
            name: x86AsFloatName(bits: bits),
            parameters: ["\(i64) v"],
            body: "return (\(float))v;"
        )
    }
    let selecting = cFunction(
        returns: i64,
        name: x86IfThenElseName,
        parameters: ["\(i64) mask", "\(i64) yes", "\(i64) no"],
        body: "return (mask & yes) | (~mask & no);"
    )
    let comparisons = [8, 32, 64].map { bits in
        let signed = x86Vector("i\(bits)")
        return cFunction(
            returns: i64,
            name: x86GreaterThanName(bits: bits),
            parameters: ["\(i64) a", "\(i64) b"],
            body: "return (\(i64))((\(signed))a > (\(signed))b);"
        )
    }
    let helpers =
        asFloats + [selecting] + comparisons + x86PartialLoadHelpers() + x86InterleaveLowerHelpers()
        + x86PartialStoreHelpers() + x86UpperHalfHelpers()
    return "#if CVECTORIZATION_OPS_X86\n\(helpers.joined())#endif"
}

func neonTable(named name: String, _ bytes: [Int]) -> String {
    cFunction(
        returns: "const uint8_t*",
        name: name,
        parameters: [],
        body: """
            static const uint8_t table[\(bytes.count)] __attribute__((aligned(16))) = {\(bytes.map(String.init).joined(separator: ", "))};
            return table;
            """
    )
}

func neonHelpers() -> String {
    let zeroing = Array(repeating: 255, count: 16)
    let slideTable = neonTable(named: neonSlideTableName, zeroing + Array(0..<16) + zeroing)
    let slideFillingTables = [SlideDirection.up, .down].map { direction in
        neonTable(
            named: neonSlideFillingTableName(direction),
            neonSlideFillingTable(direction)
        )
    }
    return "#if CVECTORIZATION_OPS_NEON\n\(([slideTable] + slideFillingTables).joined())#endif"
}

func indicesWithinBody(for element: Element) -> String {
    let unsigned = element.cUnsignedVector
    let first = splat("first", as: unsigned, lanes: element.laneCount)
    let limit = splat("limit", as: unsigned, lanes: element.laneCount)
    let exceedsLane = element.bits < 64 ? "count > UINT\(element.bits)_MAX || " : ""
    return """
        const \(element.cUnsignedLane) first = (\(element.cUnsignedLane))offset;
        const \(element.cUnsignedLane) limit = (\(element.cUnsignedLane))count;
        const \(unsigned) shifted = (\(unsigned))indices - \(first);
        return \(exceedsLane)__builtin_reduce_and(shifted < \(limit)) != 0;
        """
}

func indicesWithinFunction(for element: Element) -> String {
    cOpFunction(
        returns: .boolean,
        name: cFunctionName("indicesWithin", element),
        parameters: ["\(element.cRawVector) rawIndices", "size_t offset", "size_t count"],
        prologue: ["const \(element.cVector) indices = (\(element.cVector))rawIndices;"],
        body: cBody(TargetBodies(), for: element, portable: indicesWithinBody),
        for: element
    )
}

func rawVectorDeclarations() -> String {
    let groups = [
        (neonCondition, neonVectors),
        (sve2_128Condition, sveVectors),
        ("CVECTORIZATION_OPS_X86", x86Vectors),
    ]
    return groups.map { condition, vectors in
        let typedefs = vectors.map {
            "typedef \($0.type) \($0.name) __attribute__((\($0.attribute)));"
        }
        return (["#if \(condition)"] + typedefs + ["#endif"]).joined(separator: "\n")
    }
    .joined(separator: "\n\n")
}

func cFunction(
    returns: String,
    name: String,
    parameters: [String],
    body: String,
    specifiers: String = "CVECTORIZATION_OPS_INLINE"
) -> String {
    let signature = parameters.isEmpty ? "void" : parameters.joined(separator: ", ")
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.hasPrefix("#") ? String($0) : "  \($0)"
    }
    return """
        \(specifiers) \(returns) \(name)(\(signature)) {
        \(lines.joined(separator: "\n"))
        }

        """
}

func rawName(_ name: String) -> String {
    prefixed("raw", name)
}

func cPrologue(of op: Op, for element: Element) -> [String] {
    zip(bindings(of: op, for: element), op.parameters).compactMap { binding, parameter in
        let name = binding.swiftName
        let raw = rawName(name)
        switch parameter {
        case .vector, .indices, .laneIndices, .lookupIndices, .fillVector, .otherwiseVector:
            let operand = operandElement(of: parameter, for: element)
            return "const \(operand.cVector) \(name) = (\(operand.cVector))\(raw);"
        case .mask, .whereMask:
            return "const \(element.cMask) \(name) = (\(element.cMask))\(raw);"
        case .outVector:
            return "\(element.cBlock)* const \(name) = (\(element.cBlock)*)\(raw);"
        default:
            return nil
        }
    }
}

func cOpFunction(
    returns: ReturnType,
    name: String,
    parameters: [String],
    prologue: [String] = [],
    body: String,
    for element: Element
) -> String {
    cFunction(
        returns: cReturnType(returns, element),
        name: name,
        parameters: parameters,
        body: (prologue + [body]).joined(separator: "\n")
    )
}

func cRawConversions(of element: Element) -> String {
    let vectors = [
        (element.cToRawVector, element.cRawVector, element.cVector),
        (element.cFromRawVector, element.cVector, element.cRawVector),
    ]
    let masks = [
        (element.cToRawMask, element.cRawMask, element.cMask),
        (element.cFromRawMask, element.cMask, element.cRawMask),
    ]
    let conversions = element.hasOpaqueVector ? vectors + masks : masks
    return conversions.map { name, result, source in
        cFunction(
            returns: result,
            name: name,
            parameters: ["\(source) v"],
            body: "return (\(result))v;"
        )
    }.joined()
}

enum StaticTargetSupport {
    case arm(ArmLevel)
    case x86(X86Level)
    case portable
    case unsupported(String)

    var isSupported: Bool {
        switch self {
        case .arm, .x86, .portable: return true
        case .unsupported: return false
        }
    }

    var selection: [String] {
        switch self {
        case .arm(let level): return bodySelection(neon: level.rawValue, x86: 0, bytes: 16)
        case .x86(let level): return bodySelection(neon: 0, x86: level.rawValue, bytes: level.width)
        case .portable: return bodySelection(neon: 0, x86: 0, bytes: 16)
        case .unsupported(let message): return ["#error \"\(message)\""]
        }
    }
}

struct StaticTargetRule {
    let names: [String]
    var condition: String?
    let support: StaticTargetSupport
}

let armNeonTargets = ["NEON_BF16", "NEON", "NEON_WITHOUT_AES"]
let sveRemedy = "use SVE2 with -msve-vector-bits=128 or \(disablingFlag("HWY_ALL_SVE"))"

let staticTargetRules: [StaticTargetRule] = [
    StaticTargetRule(names: armNeonTargets, condition: "HWY_ARCH_ARM_A64", support: .arm(.neon)),
    StaticTargetRule(names: ["SVE2_128"], support: .arm(.sve2_128)),
    StaticTargetRule(names: ["AVX3"], support: .x86(.avx3)),
    StaticTargetRule(names: ["AVX3_DL", "AVX3_ZEN4", "AVX3_SPR"], support: .x86(.avx3dl)),
    StaticTargetRule(names: ["AVX2"], support: .x86(.avx2)),
    StaticTargetRule(names: ["SSE4"], support: .x86(.sse4)),
    StaticTargetRule(names: ["SSSE3"], support: .x86(.ssse3)),
    StaticTargetRule(names: ["SSE2"], support: .x86(.sse2)),
    StaticTargetRule(names: armNeonTargets, condition: "!HWY_ARCH_ARM_A64", support: .portable),
    StaticTargetRule(
        names: ["PPC8", "PPC9", "PPC10", "Z14", "Z15", "WASM", "LSX", "EMU128"],
        support: .portable
    ),
    StaticTargetRule(
        names: ["AVX10_2"],
        support: .unsupported("the port does not support highway's AVX10_2 target yet")
    ),
    StaticTargetRule(
        names: ["SVE", "SVE2"],
        condition: "!defined(__ARM_FEATURE_SVE_BITS)",
        support: .unsupported("highway sizes SVE vectors at run time: \(sveRemedy)")
    ),
    StaticTargetRule(
        names: ["SVE", "SVE2", "SVE_256"],
        condition: "defined(__ARM_FEATURE_SVE_BITS)",
        support: .unsupported(
            "the port does not support highway's fixed-size SVE targets yet: \(sveRemedy)"
        )
    ),
    StaticTargetRule(
        names: ["RVV"],
        support: .unsupported(
            "highway sizes RVV vectors at run time: use \(disablingFlag("HWY_RVV"))"
        )
    ),
    StaticTargetRule(
        names: ["LASX"],
        support: .unsupported(
            "the port does not support highway's LASX target: use \(disablingFlag("HWY_LASX"))"
        )
    ),
    StaticTargetRule(
        names: ["WASM_EMU256"],
        support: .unsupported(
            "the port does not support highway's WASM_EMU256 target: do not define HWY_WANT_WASM2"
        )
    ),
    StaticTargetRule(
        names: ["SCALAR"],
        support: .unsupported(
            "the port needs highway's EMU128 target: "
                + "do not define HWY_COMPILE_ONLY_SCALAR or HWY_NO_LIBCXX"
        )
    ),
]

let supportedX86Levels: [X86Level] = staticTargetRules.compactMap { rule in
    guard case .x86(let level) = rule.support else { return nil }
    return level
}
.sorted()

let emulatedTargets = ["SCALAR", "EMU128"]

func disablingFlag(_ targets: String) -> String {
    "-DHWY_DISABLED_TARGETS=\(targets)"
}

func bodySelection(neon: Int, x86: Int, bytes: Int) -> [String] {
    [
        "#define CVECTORIZATION_OPS_NEON \(neon)",
        "#define CVECTORIZATION_OPS_X86 \(x86)",
        "#define CVECTORIZATION_OPS_VECTOR_BYTES \(bytes)",
    ]
}

func staticTargetCondition(of names: [String]) -> String {
    let targets = names.map { "HWY_\($0)" }
    if targets.count == 1 { return "HWY_STATIC_TARGET == \(targets[0])" }
    return "HWY_STATIC_TARGET & (\(targets.joined(separator: " | ")))"
}

func staticTargetSelection() -> String {
    let chain = staticTargetRules.enumerated().flatMap { index, rule in
        let selected = staticTargetCondition(of: rule.names)
        let condition = rule.condition.map { "(\(selected)) && \($0)" } ?? selected
        return ["#\(index == 0 ? "if" : "elif") \(condition)"] + rule.support.selection
    }
    return (chain + ["#else", "#error \"unknown highway static target\"", "#endif"])
        .joined(separator: "\n")
}

func emulatedFunction() -> String {
    let emulated = emulatedTargets.map { staticTargetCondition(of: [$0]) }
    return cFunction(
        returns: "bool",
        name: "cvectorization_ops_is_emulated",
        parameters: [],
        body: "return \(emulated.joined(separator: " || "));"
    )
}

func targetNameFunction() -> String {
    let names = staticTargetRules.filter(\.support.isSupported).flatMap(\.names)
        .reduce(into: [String]()) { unique, name in
            if !unique.contains(name) {
                unique.append(name)
            }
        }
    let chain = names.enumerated().flatMap { index, name in
        [
            "#\(index == 0 ? "if" : "elif") \(staticTargetCondition(of: [name]))",
            "return \"\(name)\";",
        ]
    }
    return cFunction(
        returns: "const char*",
        name: "cvectorization_ops_target_name",
        parameters: [],
        body: (chain + ["#endif"]).joined(separator: "\n")
    )
}

func generateHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_VECTORIZATION_OPS_H
        #define SWIFT_VECTORIZATION_OPS_H

        #include <stdbool.h>
        #include <stddef.h>
        #include <stdint.h>
        #include "../vendor/detect_targets.h"

        #ifdef __cplusplus
        extern "C" {
        #endif

        #if defined(CVECTORIZATION_OPS_EXTERNAL_DEFINITIONS)
        #define CVECTORIZATION_OPS_INLINE extern inline __attribute__((always_inline)) CVECTORIZATION_OPS_VECTOR_WIDTH
        #define CVECTORIZATION_OPS_FUNCTION extern inline
        #else
        #define CVECTORIZATION_OPS_INLINE inline __attribute__((always_inline)) CVECTORIZATION_OPS_VECTOR_WIDTH
        #define CVECTORIZATION_OPS_FUNCTION inline
        #endif

        \(staticTargetSelection())

        #if CVECTORIZATION_OPS_VECTOR_BYTES == \(X86Level.avx3.width)
        #define CVECTORIZATION_OPS_VECTOR_WIDTH __attribute__((min_vector_width(\(X86Level.avx3.width * 8))))
        #else
        #define CVECTORIZATION_OPS_VECTOR_WIDTH
        #endif

        \(rawVectorDeclarations())

        \(x86Helpers())

        \(neonHelpers())

        /// Whether the target only emulates vectors, in which case a caller is better off
        /// with its own scalar code.
        \(emulatedFunction())
        /// The name of the target the ops below were compiled for.
        \(targetNameFunction())

        """

    for element in elements {
        output += """
            typedef \(element.cType) \(element.cVector) __attribute__((vector_size(CVECTORIZATION_OPS_VECTOR_BYTES)));
            typedef \(element.cMaskLane) \(element.cMask) __attribute__((vector_size(CVECTORIZATION_OPS_VECTOR_BYTES)));
            typedef \(element.cType) \(element.cBlock) __attribute__((vector_size(16)));
            #if CVECTORIZATION_OPS_X86
            typedef \(x86RawType(of: element)) \(element.cRawVector);
            typedef \(x86RawType(of: element)) \(element.cRawMask);
            #else
            typedef \(element.cVector) \(element.cRawVector);
            typedef \(element.cMask) \(element.cRawMask);
            #endif

            """
        output += cFunction(
            returns: "size_t",
            name: cFunctionName("laneCount", element),
            parameters: [],
            body: "return sizeof(\(element.cVector)) / sizeof(\(element.cType));"
        )
        output += cRawConversions(of: element)
        for size in lookupSizes where size.applies.matches(element) {
            output += cFunction(
                returns: "bool",
                name: cFunctionName(canLookupName(size.lanes), element),
                parameters: [],
                body: canLookupBody(size.lanes, for: element)
            )
        }
        if element.category != .float {
            output += indicesWithinFunction(for: element)
        }
        output += sveConstantFunction(for: element)
        if element.category == .float {
            output += sveConstantNaNFunction(for: element)
            output += sveConstantNumbersFunction(for: element)
            output += sveConstantLaneFunction(for: element)
        } else {
            output += sveSplatFunction(for: element)
        }

        for op in ops where op.applies.matches(element) {
            let parameters =
                bindings(of: op, for: element)
                .filter { !$0.cDeclaration.isEmpty }
                .map(\.cDeclaration)
            output += cHelpers(of: op, for: element)
            output += cOpFunction(
                returns: op.returns,
                name: cFunctionName(op.identifier, element),
                parameters: parameters,
                prologue: cPrologue(of: op, for: element),
                body: cBody(of: op, for: element),
                for: element
            )
            if !op.spanTargets.isEmpty {
                let arguments = parameters.map { String($0.split(separator: " ").last ?? "") }
                let call =
                    "\(cFunctionName(op.identifier, element))(\(arguments.joined(separator: ", ")))"
                output += cOpFunction(
                    returns: op.returns,
                    name: cFunctionName(op.identifier + "Span", element),
                    parameters: parameters,
                    prologue: cPrologue(of: op, for: element),
                    body: cBody(op.spanTargets, for: element, portable: { _ in "return \(call);" }),
                    for: element
                )
            }
        }

        for narrow in wideningSources(of: element) {
            let promotion = cBody(x86PromotionHelpers(from: narrow), for: element, portable: nil)
            output += "\(promotion)\n"
        }

        for op in wideningOps {
            for narrow in wideningSources(of: element) {
                let countParameters = op.takesCount ? ["size_t count"] : []
                output += cOpFunction(
                    returns: .vector,
                    name: cWideningFunctionName(op, from: narrow, to: element),
                    parameters: ["const \(narrow.cType)* from"] + countParameters,
                    body: cBody(of: op, from: narrow, to: element),
                    for: element
                )
            }
        }

        output += cOpFunction(
            returns: .vector,
            name: cFunctionName(repeatingBlockName, element),
            parameters: repeatingBlockLanes(of: element).map { "\(element.cType) \($0)" },
            body: cBody(TargetBodies(), for: element, portable: repeatingBlockBody),
            for: element
        )
        output += "\n"
    }

    output += """
        #ifdef __cplusplus
        }
        #endif

        #endif

        """
    return output
}

func swiftArgument(_ binding: Binding, _ parameter: Parameter, for element: Element) -> String {
    switch parameter {
    case .tag: return ""
    case .shiftAmount: return "Int32(truncatingIfNeeded: \(binding.swiftName))"
    default: return rawArgument(binding.swiftName, parameter, for: element)
    }
}

func rawArgument(_ name: String, _ parameter: Parameter, for element: Element) -> String {
    switch parameter {
    case .vector, .indices, .laneIndices, .lookupIndices, .fillVector, .otherwiseVector:
        return operandElement(of: parameter, for: element).hasOpaqueVector ? "\(name).raw" : name
    case .mask, .whereMask: return "\(name).raw"
    case .outVector: return element.hasOpaqueVector ? "&\(name).raw" : "&\(name)"
    default: return name
    }
}

func vectorFromRaw(_ call: String, of element: Element) -> String {
    element.hasOpaqueVector ? "Vector(raw: \(call))" : call
}

func importedType(of parameter: Parameter, for element: Element) -> String {
    switch parameter {
    case .tag: return ""
    case .vector, .indices, .laneIndices, .lookupIndices, .outVector, .fillVector,
        .otherwiseVector:
        return "\(operandElement(of: parameter, for: element).namespace).Vector"
    case .mask, .whereMask: return "\(element.namespace).Mask"
    case .lane, .fillLane: return element.swiftType
    case .constLanePointer: return "UnsafePointer<\(element.swiftType)>"
    case .lanePointer: return "UnsafeMutablePointer<\(element.swiftType)>"
    case .count, .laneAmount: return "Int"
    case .shiftAmount: return "Int32"
    }
}

func swiftDeclaration(_ binding: Binding, as type: String? = nil) -> String {
    let label = binding.swiftLabel ?? binding.swiftName
    let inoutKeyword = binding.isInOut ? "inout " : ""
    let naming =
        label == binding.swiftName
        ? binding.swiftName
        : "\(label) \(binding.swiftName)"
    return "\(naming): \(inoutKeyword)\(type ?? binding.swiftType)"
}

/// How a Swift call passes `binding`, or `expression` in its place, on to a function that has the
/// same parameter.
func swiftCallArgument(_ binding: Binding, passing expression: String? = nil) -> String {
    let label = binding.swiftLabel ?? binding.swiftName
    let operand = expression ?? binding.swiftName
    let value = binding.isInOut ? "&\(operand)" : operand
    return label == "_" ? value : "\(label): \(value)"
}

func swiftSignature(
    of op: Op,
    for element: Element,
    checked: Bool = true
) -> (parameters: String, arguments: String) {
    let parameterBindings = bindings(of: op, for: element, checked: checked)
    var declarations: [String] = []
    var arguments: [String] = []

    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        if case .tag = parameter { continue }
        declarations.append(swiftDeclaration(binding))
        arguments.append(swiftArgument(binding, parameter, for: element))
    }

    return (
        op.swiftOrdered(declarations).joined(separator: ", "), arguments.joined(separator: ", ")
    )
}

/// An op that takes a pointer is the only kind whose call is an unsafe construct, so only those
/// acknowledge it, rather than the package turning the diagnostic down for every op.
func isUnsafe(_ op: Op) -> Bool {
    op.parameters.contains { parameter in
        switch parameter {
        case .constLanePointer, .lanePointer: return true
        default: return false
        }
    }
}

func swiftBody(of op: Op, for element: Element, arguments: String, spanned: Bool = false) -> String
{
    let keyword = isUnsafe(op) ? "unsafe " : ""
    let identifier = spanned && !op.spanTargets.isEmpty ? op.identifier + "Span" : op.identifier
    let call = "\(keyword)\(cFunctionName(identifier, element))(\(arguments))"
    switch op.returns {
    case .count, .index: return "Int(\(call))"
    case .vector: return vectorFromRaw(call, of: element)
    case .mask: return "Mask(raw: \(call))"
    default: return call
    }
}

// `Span` needs newer OSes than the macOS 10.13 and iOS 12.0 SwiftPM 6.3 builds for by default.
let spanAvailability = "@available(SwiftStdlib 5.1, *)"

// A Swift parameter of a span form. The span's label differs between the forms of an op.
enum SpanParameter {
    case span
    case other(declaration: String, argument: String)
}

// A pointer op as its span forms see it, so that an `Op` and a `WideningOp` get the same ones.
// `bridgeCall` calls the bridge with the given pointer, and the given count if it takes one.
struct SpanForms {
    let name: String
    let parameters: [SpanParameter]
    let returns: ReturnType
    let extent: SpanExtent
    let element: String
    let isMutable: Bool
    var count = "$0.count"
    var checks: [Check] = []
    var bridgeCall: (_ pointer: String, _ count: String) -> String
}

func spanForms(of op: Op, for element: Element) -> SpanForms? {
    guard let extent = op.span else { return nil }
    let parameterBindings = bindings(of: op, for: element)
    let takesCountFromSpan = if case .first = extent { true } else { false }

    var parameters: [SpanParameter?] = []
    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        switch parameter {
        case .tag:
            continue
        case .count where takesCountFromSpan:
            parameters.append(nil)
        case .constLanePointer, .lanePointer:
            parameters.append(.span)
        default:
            parameters.append(
                .other(declaration: swiftDeclaration(binding), argument: swiftCallArgument(binding))
            )
        }
    }

    return SpanForms(
        name: op.swiftName,
        parameters: op.swiftOrdered(parameters).compactMap { $0 },
        returns: op.returns,
        extent: extent,
        element: "Lane",
        isMutable: op.parameters.contains(.lanePointer),
        checks: lookupChecks(of: op, for: element),
        bridgeCall: { pointer, count in
            var arguments: [String] = []
            for (binding, parameter) in zip(parameterBindings, op.parameters) {
                switch parameter {
                case .tag:
                    continue
                case .count where takesCountFromSpan:
                    arguments.append(count)
                case .constLanePointer, .lanePointer:
                    arguments.append(pointer)
                default:
                    arguments.append(swiftArgument(binding, parameter, for: element))
                }
            }
            return swiftBody(
                of: op,
                for: element,
                arguments: arguments.joined(separator: ", "),
                spanned: true
            )
        }
    )
}

func spanForms(of op: WideningOp, from narrow: Element, to wide: Element) -> SpanForms {
    let function = cWideningFunctionName(op, from: narrow, to: wide)
    return SpanForms(
        name: op.swiftName,
        parameters: [.span],
        returns: .vector,
        extent: op.span,
        element: narrow.swiftType,
        isMutable: false,
        bridgeCall: { pointer, count in
            let countArgument = op.takesCount ? ", \(count)" : ""
            return vectorFromRaw("unsafe \(function)(\(pointer)\(countArgument))", of: wide)
        }
    )
}

func checkedLabel(_ label: String, checked: Bool) -> String {
    checked ? label : "\(label)Unchecked"
}

func spanLabel(_ forms: SpanForms, checked: Bool) -> String {
    checkedLabel(forms.isMutable ? "to" : "from", checked: checked)
}

func spanSignature(_ forms: SpanForms, label: String) -> (parameters: String, arguments: String) {
    let spanType =
        forms.isMutable ? "inout MutableSpan<\(forms.element)>" : "Span<\(forms.element)>"
    let spanArgument = forms.isMutable ? "&span" : "span"
    var declarations: [String] = []
    var arguments: [String] = []
    for parameter in forms.parameters {
        switch parameter {
        case .span:
            declarations.append("\(label) span: \(spanType)")
            arguments.append("\(label): \(spanArgument)")
        case .other(let declaration, let argument):
            declarations.append(declaration)
            arguments.append(argument)
        }
    }
    return (declarations.joined(separator: ", "), arguments.joined(separator: ", "))
}

typealias Check = (condition: String, message: String)

/// What a span form checks before it touches `count` vectors' worth of lanes, each as a Swift
/// condition and the message for when it fails.
func spanChecks(vectors count: Int, aligned: Bool) -> [Check] {
    var checks = [
        count > 1
            ? (
                "span.count >= \(count) * laneCount",
                "Span has fewer elements than \(count) vectors have lanes"
            )
            : ("span.count >= laneCount", "Span has fewer elements than a vector has lanes")
    ]
    if aligned {
        checks.append(
            (
                "span.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) "
                    + "% UInt(laneCount * MemoryLayout<Lane>.stride) == 0 }",
                "Span does not start at an address aligned to the vector size"
            )
        )
    }
    return checks
}

/// What a span form checks before it touches the `lanes` of a table, each as a Swift condition and
/// the message for when it fails. The span must start at an address aligned to the table's size.
func spanChecks(table lanes: Int) -> [Check] {
    [
        ("span.count >= \(lanes)", "Span has fewer elements than the table has lanes"),
        (
            "span.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) "
                + "% UInt(\(lanes) * MemoryLayout<Lane>.stride) == 0 }",
            "Span does not start at an address aligned to the table size"
        ),
    ]
}

/// A checked member that traps when any of `checks` fails, and the `@unsafe` unchecked member it
/// calls, which only asserts them, like `Span`'s `subscript(_:)` and `subscript(unchecked:)`.
func checkedMembers(
    _ name: String,
    availability: String? = nil,
    checked: String,
    unchecked: (parameters: String, arguments: String),
    returnClause: String,
    checks: [Check],
    uncheckedBody: String
) -> String {
    let returnKeyword = returnClause.isEmpty ? "" : "return "
    let attributes = availability.map { "\($0)\n" } ?? ""
    let preconditions = checks.map { "precondition(\($0.condition), \"\($0.message)\")" }
    let assertions = checks.map { "assert(\($0.condition), \"\($0.message)\")" }
    return """
            \(attributes)@export(implementation) @inline(always)
            public static func \(name)(\(checked))\(returnClause) {
                \(preconditions.joined(separator: "\n"))
                \(returnKeyword)unsafe \(name)(\(unchecked.arguments))
            }

            \(attributes)@unsafe @export(implementation) @inline(always)
            public static func \(name)(\(unchecked.parameters))\(returnClause) {
                \(assertions.joined(separator: "\n"))
                \(uncheckedBody)
            }


        """
}

/// The members that take a span where `forms`' op takes a pointer. A `first` op never touches
/// more than the span has, so it has one form. The others have a checked form that traps when
/// the span is too short or misaligned, and an `@unsafe` unchecked one that only asserts it.
func spanMembers(_ forms: SpanForms) -> String {
    let returnClause = forms.returns == .void ? "" : " -> \(swiftReturnType(forms.returns))"
    let returnKeyword = forms.returns == .void ? "" : "return "
    let accessor = forms.isMutable ? "withUnsafeMutableBufferPointer" : "withUnsafeBufferPointer"
    let checked = spanSignature(forms, label: spanLabel(forms, checked: true))

    let checks: [Check]
    switch forms.extent {
    case .first:
        return """
                \(spanAvailability)
                @export(implementation) @inline(always)
                public static func \(forms.name)(\(checked.parameters))\(returnClause) {
                    span.\(accessor) { \(forms.bridgeCall("$0.baseAddress", forms.count)) }
                }


            """
    case .vectors(let count, let aligned):
        checks = spanChecks(vectors: count, aligned: aligned)
    case .table(let lanes):
        checks = spanChecks(table: lanes)
    }

    let unchecked = spanSignature(forms, label: spanLabel(forms, checked: false))
    let bridgeCall = forms.bridgeCall("$0.baseAddress.unsafelyUnwrapped", "$0.count")
    return checkedMembers(
        forms.name,
        availability: spanAvailability,
        checked: checked.parameters,
        unchecked: unchecked,
        returnClause: returnClause,
        checks: checks + forms.checks,
        uncheckedBody: """
            \(returnKeyword)span.\(accessor) {
                \(bridgeCall)
            }
            """
    )
}

func takesLaneAmount(_ op: Op) -> Bool {
    op.parameters.contains(.laneAmount)
}

func takesIndices(_ op: Op) -> Bool {
    op.parameters.contains { $0 == .indices || $0 == .laneIndices }
}

func takesLookupIndices(_ op: Op) -> Bool {
    op.parameters.contains(.lookupIndices)
}

func hasCheckedForms(_ op: Op) -> Bool {
    takesLaneAmount(op) || takesIndices(op)
}

/// What a lane amount form checks before it hands the amount on, as a Swift condition and the
/// message for when it fails. Highway's NEON slides read their index tables out of bounds above
/// `laneCount`.
func laneAmountChecks() -> [Check] {
    [
        (
            "lanes >= 0 && lanes <= laneCount",
            "Lane amount is negative or more than a vector has lanes"
        )
    ]
}

/// What a lookup form checks before it hands the indices on, as a Swift condition and the message
/// for when it fails: one unsigned comparison of every index and one reduction of the results.
func indexChecks(of op: Op, for element: Element) -> [Check] {
    guard let contract = op.indexContract,
        let parameter = op.parameters.first(where: { $0 == .indices || $0.isLaneIndices })
    else { return [] }
    let function = cFunctionName("indicesWithin", operandElement(of: parameter, for: element))
    let count = contract.count.expression(laneCount: "laneCount")
    return [("\(function)(indices.raw, \(contract.offset), \(count))", contract.message)]
}

func uncheckedFormChecks(of op: Op, for element: Element) -> [Check] {
    takesIndices(op) ? indexChecks(of: op, for: element) : laneAmountChecks()
}

/// The members of an op that takes a lane amount or indices: a checked form that traps on those
/// outside the range its checks accept, and an `@unsafe` unchecked one that only asserts it.
func checkedFormMembers(of op: Op, for element: Element) -> String {
    let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
    let returnKeyword = op.returns == .void ? "" : "return "
    let checked = swiftSignature(of: op, for: element)
    let unchecked = swiftSignature(of: op, for: element, checked: false)
    var uncheckedArguments: [String] = []
    for (binding, parameter) in zip(bindings(of: op, for: element, checked: false), op.parameters) {
        if case .tag = parameter { continue }
        uncheckedArguments.append(swiftCallArgument(binding))
    }
    let body = swiftBody(of: op, for: element, arguments: unchecked.arguments)
    return checkedMembers(
        op.swiftName,
        checked: checked.parameters,
        unchecked: (
            unchecked.parameters, op.swiftOrdered(uncheckedArguments).joined(separator: ", ")
        ),
        returnClause: returnClause,
        checks: uncheckedFormChecks(of: op, for: element),
        uncheckedBody: "\(returnKeyword)\(body)"
    )
}

func checkedFormRequirements(of op: Op, indent: String) -> String {
    let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
    let unchecked = swiftSignature(of: op, for: elements[0], checked: false)
    return "\(indent)@unsafe static func \(op.swiftName)(\(unchecked.parameters))\(returnClause)\n"
}

func spanRequirements(_ forms: SpanForms, indent: String) -> String {
    let returnClause = forms.returns == .void ? "" : " -> \(swiftReturnType(forms.returns))"
    let checked = spanSignature(forms, label: spanLabel(forms, checked: true))
    var output = "\(indent)\(spanAvailability)\n"
    output += "\(indent)static func \(forms.name)(\(checked.parameters))\(returnClause)\n"
    if case .first = forms.extent { return output }
    let unchecked = spanSignature(forms, label: spanLabel(forms, checked: false))
    output += "\(indent)\(spanAvailability)\n"
    output += "\(indent)@unsafe static func \(forms.name)(\(unchecked.parameters))\(returnClause)\n"
    return output
}

/// The name of the form of a store op that appends to an `OutputSpan`, after `UniqueArray`'s
/// `append`s. A `first` op appends as many lanes as it is told to, so it is
/// `append(_:addingCount:to:)`.
func outputSpanName(_ forms: SpanForms) -> String {
    if case .first = forms.extent { return "append" }
    return "append\(forms.name.dropFirst("store".count))"
}

func outputSpanSignature(
    _ forms: SpanForms,
    checked: Bool
) -> (parameters: String, arguments: String) {
    let label = checkedLabel("to", checked: checked)
    let takesCount = if case .first = forms.extent { true } else { false }
    var declarations: [String] = []
    var arguments: [String] = []
    for parameter in forms.parameters {
        switch parameter {
        case .span:
            if takesCount {
                declarations.append("addingCount: Int")
                arguments.append("addingCount: addingCount")
            }
            declarations.append("\(label) output: inout OutputSpan<\(forms.element)>")
            arguments.append("\(label): &output")
        case .other(let declaration, let argument):
            declarations.append(declaration)
            arguments.append(argument)
        }
    }
    return (declarations.joined(separator: ", "), arguments.joined(separator: ", "))
}

/// What an output span form checks before it appends, each as a Swift condition and the message
/// for when it fails. An `aligned` op also needs the lanes it appends to start at an address
/// aligned to the vector size.
func outputSpanChecks(_ extent: SpanExtent) -> [Check] {
    guard case .vectors(let count, let aligned) = extent else {
        return [
            ("addingCount >= 0 && addingCount <= laneCount", "Count out of bounds"),
            (
                "addingCount <= output.freeCapacity",
                "OutputSpan has less free capacity than the count"
            ),
        ]
    }
    var checks = [
        count > 1
            ? (
                "output.freeCapacity >= \(count) * laneCount",
                "OutputSpan has less free capacity than \(count) vectors have lanes"
            )
            : (
                "output.freeCapacity >= laneCount",
                "OutputSpan has less free capacity than a vector has lanes"
            )
    ]
    if aligned {
        checks.append(
            (
                "output.span.withUnsafeBufferPointer { (UInt(bitPattern: $0.baseAddress) "
                    + "&+ UInt($0.count &* MemoryLayout<Lane>.stride)) "
                    + "% UInt(laneCount * MemoryLayout<Lane>.stride) == 0 }",
                "OutputSpan does not continue at an address aligned to the vector size"
            )
        )
    }
    return checks
}

/// The members that append to an `OutputSpan` where `forms`' store op takes a pointer. Like the
/// span forms, a checked form traps when the output span has too little free capacity, the count
/// is out of bounds, or the lanes would be misaligned, and an `@unsafe` unchecked one only
/// asserts it. An empty `OutputSpan` can have no buffer at all, which only a `first` op can be
/// given, to append no lanes to.
func outputSpanMembers(_ forms: SpanForms) -> String {
    let name = outputSpanName(forms)
    let checked = outputSpanSignature(forms, checked: true)
    let unchecked = outputSpanSignature(forms, checked: false)
    let (pointer, appendedCount) =
        switch forms.extent {
        case .first:
            ("buffer.baseAddress?.advanced(by: initializedCount)", "addingCount")
        case .vectors(let count, _):
            (
                "buffer.baseAddress.unsafelyUnwrapped + initializedCount",
                count > 1 ? "\(count) * laneCount" : "laneCount"
            )
        case .table:
            fatalError("A table is not an output")
        }
    return checkedMembers(
        name,
        availability: spanAvailability,
        checked: checked.parameters,
        unchecked: unchecked,
        returnClause: "",
        checks: outputSpanChecks(forms.extent),
        uncheckedBody: """
            unsafe output.withUnsafeMutableBufferPointer { buffer, initializedCount in
                \(forms.bridgeCall(pointer, "addingCount"))
                initializedCount &+= \(appendedCount)
            }
            """
    )
}

func outputSpanRequirements(_ forms: SpanForms, indent: String) -> String {
    let name = outputSpanName(forms)
    let checked = outputSpanSignature(forms, checked: true)
    let unchecked = outputSpanSignature(forms, checked: false)
    var output = "\(indent)\(spanAvailability)\n"
    output += "\(indent)static func \(name)(\(checked.parameters))\n"
    output += "\(indent)\(spanAvailability)\n"
    output += "\(indent)@unsafe static func \(name)(\(unchecked.parameters))\n"
    return output
}

let integerElements = elements.filter { $0.category != .float }
let floatElements = elements.filter { $0.category == .float }

func opsApplyingToAll(_ candidates: [Element]) -> [Op] {
    ops.filter { op in candidates.allSatisfy(op.applies.matches) }
}

let universalOps = opsApplyingToAll(elements)
let integerOnlyOps = opsApplyingToAll(integerElements)
    .filter { op in !universalOps.contains { $0.identifier == op.identifier } }
let floatOnlyOps = opsApplyingToAll(floatElements)
    .filter { op in !universalOps.contains { $0.identifier == op.identifier } }

func protocolRequirements(_ requirementOps: [Op], indent: String) -> String {
    var output = ""
    for op in requirementOps {
        let signature = swiftSignature(of: op, for: elements[0])
        let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
        output += "\(indent)static func \(op.swiftName)(\(signature.parameters))\(returnClause)\n"
        if hasCheckedForms(op) {
            output += checkedFormRequirements(of: op, indent: indent)
        }
        if let forms = spanForms(of: op, for: elements[0]) {
            output += spanRequirements(forms, indent: indent)
            if forms.isMutable {
                output += outputSpanRequirements(forms, indent: indent)
            }
        }
    }
    return output
}

func generateProtocols() -> String {
    let declarations = """
        /// An element type that vectors can hold, and the ops every such type has.
        ///
        /// Conformances are the `SIMD…` enumerations, so that a kernel can be written once and
        /// used for any element type: `func sum<E: SIMDElement>(_ type: E.Type, …)`.
        public protocol SIMDElement {
            associatedtype Lane
            associatedtype Vector
            associatedtype Mask
            associatedtype Indices

            /// How many lanes of `Lane` a `Vector` holds on the target this was compiled for.
            static var laneCount: Int { get }

        \(protocolRequirements(universalOps, indent: "    "))}

        /// The ops that only the integer element types have.
        public protocol SIMDIntegerElement: SIMDElement {
        \(protocolRequirements(integerOnlyOps, indent: "    "))}

        /// The ops that only the floating point element types have.
        public protocol SIMDFloatElement: SIMDElement {
        \(protocolRequirements(floatOnlyOps, indent: "    "))}
        """

    return "\(generationNotice)\n\n\(declarations)\n"
}

func vectorDeclaration(of element: Element) -> String {
    """
    public struct Vector: Sendable {
        /// The SIMD type a `Vector` converts to and from, whose width is the target's.
        public typealias SIMDType = \(element.cVector)

        public var raw: \(element.cRawVector)

        @export(implementation) @inline(always)
        public init(raw: \(element.cRawVector)) {
            self.raw = raw
        }

        @export(implementation) @inline(always)
        public init(_ simd: SIMDType) {
            raw = \(element.cToRawVector)(simd)
        }

        @export(implementation) @inline(always)
        public var simd: SIMDType { \(element.cFromRawVector)(raw) }
    }
    """
}

func maskDeclaration(of element: Element) -> String {
    """
    public struct Mask: Sendable {
        /// The SIMD mask type a `Mask` converts to and from, whose width is the target's.
        public typealias SIMDType = SIMDMask<\(element.cMask)>

        public var raw: \(element.cRawMask)

        @export(implementation) @inline(always)
        public init(raw: \(element.cRawMask)) {
            self.raw = raw
        }

        @export(implementation) @inline(always)
        public init(_ simd: SIMDType) {
            raw = \(element.cToRawMask)(simd._storage)
        }

        @export(implementation) @inline(always)
        public var simd: SIMDType {
            SIMDType(\(element.cFromRawMask)(raw))
        }
    }
    """
}

func indicesDeclaration(of element: Element) -> String {
    "public typealias Indices = \(laneIndexElement(of: element).namespace).Vector"
}

func typeDeclarations(of element: Element) -> String {
    let lane = "public typealias Lane = \(element.swiftType)"
    let mask = maskDeclaration(of: element)
    let indices = indicesDeclaration(of: element)
    guard element.hasOpaqueVector else {
        return "\(lane)\npublic typealias Vector = \(element.cVector)\n\n\(mask)\n\n\(indices)"
    }
    return "\(lane)\n\n\(vectorDeclaration(of: element))\n\n\(mask)\n\n\(indices)"
}

func generateElement(_ element: Element) -> String {
    var conformances = ["SIMDElement"]
    if element.category == .float {
        conformances.append("SIMDFloatElement")
    } else {
        conformances.append("SIMDIntegerElement")
    }
    conformances.append("SendableMetatype")

    var output = """
        \(generationNotice)

        public import CVectorizationOps

        /// Vectors of `\(element.swiftType)`, and the ops over them.
        public enum \(element.namespace): \(conformances.joined(separator: ", ")) {
            \(typeDeclarations(of: element))

            @export(implementation) @inline(always)
            public static var laneCount: Int { Int(\(cFunctionName("laneCount", element))()) }


        """
    output += canLookupMembers(for: element)

    for op in ops where op.applies.matches(element) {
        if hasCheckedForms(op) {
            output += checkedFormMembers(of: op, for: element)
            continue
        }
        let signature = swiftSignature(of: op, for: element)
        let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
        let body = swiftBody(of: op, for: element, arguments: signature.arguments)
        output += "    @export(implementation) @inline(always)\n"
        output +=
            "    public static func \(op.swiftName)(\(signature.parameters))\(returnClause) {\n"
        let assertions = lookupAssertions(of: op, for: element)
        output += assertions
        output += "        \(assertions.isEmpty ? "" : "return ")\(body)\n"
        output += "    }\n\n"
        if let forms = spanForms(of: op, for: element) {
            output += spanMembers(forms)
            if forms.isMutable {
                output += outputSpanMembers(forms)
            }
        }
    }

    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            let countParameter = op.takesCount ? ", count: Int" : ""
            let countArgument = op.takesCount ? ", count" : ""
            let function = cWideningFunctionName(op, from: narrow, to: element)
            output += "    @export(implementation) @inline(always)\n"
            output += "    public static func \(op.swiftName)("
            output += "from: UnsafePointer<\(narrow.swiftType)>\(countParameter)"
            output += ") -> Vector {\n"
            let call = "unsafe \(function)(from\(countArgument))"
            output += "        \(vectorFromRaw(call, of: element))\n"
            output += "    }\n\n"
            output += spanMembers(spanForms(of: op, from: narrow, to: element))
        }
    }

    let blockLanes = repeatingBlockLanes(of: element)
    output += "    @export(implementation) @inline(always)\n"
    output += "    public static func \(repeatingBlockName)("
    output += blockLanes.map { "_ \($0): Lane" }.joined(separator: ", ")
    output += ") -> Vector {\n"
    let blockFunction = cFunctionName(repeatingBlockName, element)
    let blockCall = "\(blockFunction)(\(blockLanes.joined(separator: ", ")))"
    output += "        \(vectorFromRaw(blockCall, of: element))\n"
    output += "    }\n\n"

    output += "}\n\n\(unavailableSendableConformance(of: element.namespace))\n"

    return output
}

func fnv1a(_ text: String) -> UInt64 {
    text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
}

func referenceTestSeed(_ element: Element, _ test: String, _ input: String) -> String {
    String(format: "0x%016llX", fnv1a("\(element.suffix)/\(test)/\(input)"))
}

struct ReferenceInput {
    let parameter: Parameter
    let name: String
    let values: String

    var description: String {
        switch parameter {
        case .lane, .fillLane: return "hex(\(name))"
        case .count, .shiftAmount, .laneAmount: return name
        default: return "describe(\(name))"
        }
    }
}

func hasOutOfContractInputs(_ op: Op) -> Bool {
    op.parameters.contains { parameter in
        switch parameter {
        case .shiftAmount, .laneAmount, .indices, .laneIndices, .lookupIndices: return true
        default: return false
        }
    }
}

func isAligned(_ op: Op) -> Bool {
    switch op.span {
    case .vectors(_, let aligned)?: return aligned
    case .table?: return true
    case .first?, nil: return false
    }
}

/// The lanes whose size a pointer op's address must be aligned to.
func alignmentLanes(of op: Op) -> String {
    if case .table(let lanes)? = op.span { return String(lanes) }
    return "H.laneCount"
}

func pointerLanes(of op: Op) -> String {
    switch op.span {
    case .vectors(let count, _)?: return count == 1 ? "H.laneCount" : "\(count) * H.laneCount"
    case .first?: return "H.laneCount"
    case .table(let lanes)?: return String(lanes)
    case nil: fatalError("\(op.swiftName) takes a pointer but has no span extent")
    }
}

func pointerExpression(_ closureParameter: String, aligned: Bool) -> String {
    aligned ? closureParameter : "\(closureParameter).baseAddress!"
}

/// The lanes of `buffer` that a pointer op with `extent` may touch, which a guarded test puts right
/// before an inaccessible page.
func guardedLanes(of buffer: String, extent: SpanExtent?, count: String = "count") -> String {
    guard case .first? = extent else { return buffer }
    return "Array(\(buffer).prefix(\(count)))"
}

func indexInputs(
    of op: Op,
    _ parameter: Parameter,
    seed: String,
    inContract: Bool
) -> String {
    guard let contract = op.indexContract else {
        fatalError("\(op.swiftName) takes indices but has no index contract")
    }
    let type = parameter.isLaneIndices ? "H.Indices" : "H.Vector"
    let offset = contract.offset == 0 ? "" : "offset: \(contract.offset), "
    let count = contract.count.expression(laneCount: "H.laneCount")
    let arguments = "\(type).self, \(offset)count: \(count), \(seed), inContract: \(inContract)"
    return "Inputs.tableIndices(\(arguments))"
}

func referenceInputs(
    of op: Op,
    for element: Element,
    test: String,
    inContract: Bool
) -> [ReferenceInput] {
    var inputs: [ReferenceInput] = []
    for (binding, parameter) in zip(bindings(of: op, for: element), op.parameters) {
        let seed = "seed: \(referenceTestSeed(element, test, String(inputs.count)))"
        let values: String
        switch parameter {
        case .tag, .lanePointer, .outVector:
            continue
        case .vector, .fillVector, .otherwiseVector:
            values = "Inputs.vectors(H.Vector.self, \(seed))"
        case .indices, .laneIndices, .lookupIndices:
            values = indexInputs(of: op, parameter, seed: seed, inContract: inContract)
        case .mask, .whereMask:
            values = "Inputs.masks(H.Mask.self, \(seed))"
        case .lane, .fillLane:
            values = "Inputs.lanes(H.Lane.self, \(seed))"
        case .count where op.span != nil:
            values = "Inputs.bufferCounts(lanes: H.laneCount)"
        case .count:
            values = "Inputs.maskCounts(lanes: H.laneCount, lane: \(element.swiftMaskLane).self)"
        case .shiftAmount:
            values = "Inputs.shiftAmounts(bits: \(element.bits), inContract: \(inContract))"
        case .laneAmount:
            values = "Inputs.laneAmounts(lanes: H.laneCount, inContract: \(inContract))"
        case .constLanePointer:
            let lanes = pointerLanes(of: op)
            values = "Inputs.buffers(H.Lane.self, count: \(lanes), \(seed))"
        }
        inputs.append(ReferenceInput(parameter: parameter, name: binding.swiftName, values: values))
    }
    return inputs
}

let referenceCombinators = [2: "everyPair", 3: "mixedTriples", 4: "mixedQuadruples"]

func referenceLoop(
    over inputs: [ReferenceInput],
    for element: Element,
    test: String,
    where condition: String? = nil
) -> String? {
    guard let first = inputs.first else { return nil }
    let filter = condition.map { " where \($0)" } ?? ""
    guard inputs.count > 1 else { return "for \(first.name) in \(first.name)Inputs\(filter)" }
    guard let combinator = referenceCombinators[inputs.count] else {
        fatalError("\(test) has \(inputs.count) inputs, which nothing combines")
    }
    var arguments = inputs.map { "\($0.name)Inputs" }
    if inputs.count > 2 {
        arguments.append("seed: \(referenceTestSeed(element, test, "combinations"))")
    }
    let names = inputs.map(\.name).joined(separator: ", ")
    return "for (\(names)) in \(combinator)(\(arguments.joined(separator: ", ")))\(filter)"
}

func referenceDescription(of inputs: [ReferenceInput], suffix: String = "") -> String {
    let fields = inputs.map { "\($0.name): \\(\($0.description))" }
    return "\"\(fields.joined(separator: ", "))\(suffix)\""
}

func portCall(_ name: String, _ arguments: [String], on type: String = "H") -> String {
    "\(type).\(name)(\(arguments.joined(separator: ", ")))"
}

let referenceNothrowNamespace = "HighwayReference.Nothrow"

func referenceCall(
    _ name: String,
    _ arguments: [String],
    in namespace: String = "HighwayReference"
) -> String {
    "\(namespace).\(name)(\(arguments.joined(separator: ", ")))"
}

func referenceNothrowWrapper(
    returning type: String,
    named name: String,
    declarations: String
) -> String {
    let arguments = declarations.split(separator: ",").compactMap {
        $0.split(whereSeparator: { " &*".contains($0) }).last
    }
    let call = "::HighwayReference::\(name)(\(arguments.joined(separator: ", ")))"
    return
        "HWY_INLINE \(type) \(name)(\(declarations)) noexcept { \(type == "void" ? "" : "return ")\(call); }\n"
}

func referenceResult(
    _ call: String,
    returning returns: ReturnType,
    for element: Element,
    on type: String = "H"
) -> String {
    switch returns {
    case .vector: return opaqueVector(call, of: element, on: type)
    case .mask: return "\(type).Mask(raw: \(call))"
    default: return call
    }
}

func referenceCalls(
    of op: Op,
    for element: Element,
    pointer: String,
    checked: Bool = true,
    constants: [String: (port: String, reference: String)] = [:]
) -> (port: String, reference: String) {
    var portArguments: [String] = []
    var referenceArguments: [String] = []
    var outVectorIndex = 0

    for (binding, parameter) in zip(bindings(of: op, for: element, checked: checked), op.parameters)
    {
        if let constant = constants[binding.swiftName] {
            portArguments.append(swiftCallArgument(binding, passing: constant.port))
            referenceArguments.append(rawArgument(constant.reference, parameter, for: element))
            continue
        }
        switch parameter {
        case .tag:
            continue
        case .vector, .indices, .laneIndices, .lookupIndices, .mask, .fillVector, .whereMask,
            .otherwiseVector, .lane, .fillLane, .count, .shiftAmount, .laneAmount:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append(swiftArgument(binding, parameter, for: element))
        case .constLanePointer, .lanePointer:
            portArguments.append(swiftCallArgument(binding, passing: pointer))
            referenceArguments.append(pointer)
        case .outVector:
            portArguments.append(swiftCallArgument(binding, passing: "p\(outVectorIndex)"))
            referenceArguments.append(
                rawArgument("r\(outVectorIndex)", parameter, for: element)
            )
            outVectorIndex += 1
        }
    }

    let keyword = isUnsafe(op) ? "unsafe " : ""
    let portKeyword = isUnsafe(op) || !checked ? "unsafe " : ""
    let call = referenceCall(referenceFunctionName(op.identifier, element), referenceArguments)
    let reference = referenceResult(call, returning: op.returns, for: element)
    let port = portCall(op.swiftName, op.swiftOrdered(portArguments))
    return ("\(portKeyword)\(port)", "\(keyword)\(reference)")
}

typealias Disabling = (condition: String, reason: String)

func emulationDisabling(_ reason: String) -> Disabling {
    ("SIMDTarget.targetName == \"EMU128\"", reason)
}

let assertionsDisabling: Disabling = (
    "assertionsAreEnabled", "Assertions abort the test run on these indices"
)

func outOfContractDisabling(of op: Op) -> [Disabling] {
    if op.parameters.contains(.shiftAmount) {
        return [emulationDisabling("EMU128 has no defined result for these shift counts")]
    }
    guard let contract = op.indexContract else { return [] }
    return [assertionsDisabling]
        + (contract.isDefinedOnEmulation
            ? [] : [emulationDisabling("EMU128 reads outside the vector for these indices")])
}

func lookupDisabling(of op: Op) -> [Disabling] {
    guard case .table(let lanes)? = op.span else { return [] }
    let reason = "Highway's lookup needs more lanes than this target has"
    return [("!H.\(canLookupName(lanes))", reason)]
}

func testAttribute(disabling: [Disabling]) -> String {
    let traits = disabling.map { ".disabled(if: \($0.condition), \"\($0.reason)\")" }
    return "@Test(\(traits.joined(separator: ", ")))"
}

func referenceTestFunction(
    _ test: String,
    label: String,
    for element: Element,
    inputs: [ReferenceInput],
    declarations: [String] = [],
    disabling: [Disabling] = [],
    signature: String? = nil,
    loopCondition: String? = nil,
    statements: String
) -> String {
    let header =
        signature
        ?? (disabling.isEmpty
            ? "@Test func \(test)() {"
            : "\(testAttribute(disabling: disabling))\nfunc \(test)() {")
    var lines = ["let mismatches = Mismatches(\"\(label)\")"]
    lines += inputs.map { "let \($0.name)Inputs = \($0.values)" }
    lines += declarations
    if let loop = referenceLoop(
        over: inputs,
        for: element,
        test: test,
        where: loopCondition
    ) {
        lines.append("\(loop) {\n\(statements)\n}")
    } else {
        lines.append(statements)
    }
    lines.append("mismatches.record()")
    return """
        \(header)
        \(lines.joined(separator: "\n"))
        }
        """
}

func alignedLanes(_ lanes: String, to laneCount: String = "H.laneCount") -> String {
    "withAlignedLanes(\(lanes), laneCount: \(laneCount))"
}

func referenceLoadStatements(
    of source: String,
    aligned: Bool,
    alignedTo laneCount: String = "H.laneCount",
    guardedLanes: String?,
    port: String,
    reference: String,
    description: String
) -> String {
    let results = "(\(port), \(reference))"
    let scope =
        if let guardedLanes {
            "unsafe withGuardedLanes(\(guardedLanes)) { source in \(results) }.result"
        } else if aligned {
            "unsafe \(alignedLanes(source, to: laneCount)) { source in \(results) }.result"
        } else {
            "\(source).withUnsafeBufferPointer { source in \(results) }"
        }
    return """
        let (portResult, referenceResult) = \(scope)
        mismatches.check(portResult, referenceResult, \(description))
        """
}

func referenceOutVectorStatements(
    of source: String,
    count: Int,
    for element: Element,
    guardedLanes: String?,
    port: String,
    reference: String,
    inputs: [ReferenceInput]
) -> String {
    let zero = referenceResult(
        referenceCall(referenceFunctionName("zero", element), []),
        returning: .vector,
        for: element
    )
    var statements = (0..<count).map { "var p\($0) = \(portCall("zero", []))" }
    statements += (0..<count).map { "var r\($0) = \(zero)" }
    let calls = "{ source in\n\(port)\n\(reference)\n}"
    if let guardedLanes {
        statements.append("_ = unsafe withGuardedLanes(\(guardedLanes)) \(calls)")
    } else {
        statements.append("\(source).withUnsafeBufferPointer \(calls)")
    }
    for index in 0..<count {
        let description = referenceDescription(of: inputs, suffix: ", v\(index)")
        statements.append("mismatches.check(p\(index), r\(index), \(description))")
    }
    return statements.joined(separator: "\n")
}

func referenceStoreStatements(
    aligned: Bool,
    guardedLanes: String?,
    port: String,
    reference: String,
    description: String
) -> String {
    let stores = [("portLanes", port), ("referenceLanes", reference)].map { lanes, call in
        let closure = "{ destination in \(call) }"
        if let guardedLanes {
            return "let \(lanes) = unsafe withGuardedLanes(\(guardedLanes)) \(closure).lanes"
        }
        return aligned
            ? "let \(lanes) = unsafe \(alignedLanes("sentinel")) \(closure).lanes"
            : "var \(lanes) = sentinel\n\(lanes).withUnsafeMutableBufferPointer \(closure)"
    }
    let comparison = "mismatches.check(portLanes, referenceLanes, \(description))"
    return (stores + [comparison]).joined(separator: "\n")
}

func referencePointer(of op: Op, guarded: Bool) -> String {
    let isStore = op.parameters.contains(.lanePointer)
    return pointerExpression(isStore ? "destination" : "source", aligned: isAligned(op) || guarded)
}

func referenceStatements(
    of op: Op,
    for element: Element,
    inputs: [ReferenceInput],
    guarded: Bool,
    count: String = "count",
    calls: (port: String, reference: String)
) -> (declarations: [String], statements: String) {
    let description = referenceDescription(of: inputs)
    let aligned = isAligned(op)
    let isStore = op.parameters.contains(.lanePointer)
    var declarations: [String] = []
    let statements: String

    if let source = inputs.first(where: { $0.parameter == .constLanePointer })?.name {
        let outVectors = op.parameters.filter { $0 == .outVector }.count
        statements =
            outVectors == 0
            ? referenceLoadStatements(
                of: source,
                aligned: aligned,
                alignedTo: alignmentLanes(of: op),
                guardedLanes: guarded
                    ? guardedLanes(of: source, extent: op.span, count: count) : nil,
                port: calls.port,
                reference: calls.reference,
                description: description
            )
            : referenceOutVectorStatements(
                of: source,
                count: outVectors,
                for: element,
                guardedLanes: guarded
                    ? guardedLanes(of: source, extent: op.span, count: count) : nil,
                port: calls.port,
                reference: calls.reference,
                inputs: inputs
            )
    } else if isStore {
        let lanes = pointerLanes(of: op)
        let sentinelCount = guarded ? lanes : "\(lanes) + 4"
        declarations.append("let sentinel = Inputs.sentinel(H.Lane.self, count: \(sentinelCount))")
        statements = referenceStoreStatements(
            aligned: aligned,
            guardedLanes: guarded
                ? guardedLanes(of: "sentinel", extent: op.span, count: count) : nil,
            port: calls.port,
            reference: calls.reference,
            description: description
        )
    } else {
        statements = "mismatches.check(\(calls.port), \(calls.reference), \(description))"
    }

    return (declarations, statements)
}

func referenceTest(
    of op: Op,
    for element: Element,
    inContract: Bool,
    checked: Bool = true,
    guarded: Bool = false
) -> String {
    let (test, label) =
        if guarded {
            ("\(op.identifier)BeforeGuardPage", "\(op.identifier) before a guard page")
        } else if !inContract {
            ("\(op.identifier)OutOfContract", "\(op.identifier) out of contract")
        } else if checked {
            (op.identifier, op.identifier)
        } else {
            ("\(op.identifier)Unchecked", "\(op.identifier) unchecked")
        }
    let inputs = referenceInputs(of: op, for: element, test: test, inContract: inContract)
    let calls = referenceCalls(
        of: op,
        for: element,
        pointer: referencePointer(of: op, guarded: guarded),
        checked: checked
    )
    let (declarations, statements) = referenceStatements(
        of: op,
        for: element,
        inputs: inputs,
        guarded: guarded,
        calls: calls
    )

    return referenceTestFunction(
        test,
        label: label,
        for: element,
        inputs: inputs,
        declarations: declarations,
        disabling: lookupDisabling(of: op) + (inContract ? [] : outOfContractDisabling(of: op)),
        statements: statements
    )
}

func wideningReferenceTest(
    _ op: WideningOp,
    from narrow: Element,
    to wide: Element,
    guarded: Bool = false,
    constantCount: Bool = false
) -> String {
    let name = "\(op.swiftName)From\(narrow.swiftType)"
    let guardedName = guarded ? "\(name)BeforeGuardPage" : name
    let test = constantCount ? "check\(uppercasedFirst(guardedName))ConstantCount" : guardedName
    let seed = "seed: \(referenceTestSeed(wide, test, "0"))"
    var inputs = [
        ReferenceInput(
            parameter: .constLanePointer,
            name: "from",
            values: "Inputs.buffers(\(narrow.swiftType).self, count: H.laneCount, \(seed))"
        )
    ]
    let pointer = pointerExpression("source", aligned: guarded)
    var portArguments = ["from: \(pointer)"]
    var referenceArguments = [pointer]
    if op.takesCount {
        if !constantCount {
            inputs.append(
                ReferenceInput(
                    parameter: .count,
                    name: "count",
                    values: "Inputs.bufferCounts(lanes: H.laneCount)"
                )
            )
        }
        portArguments.append("count: count")
        referenceArguments.append(guarded ? "min(count, H.laneCount)" : "count")
    }

    let function = wideningFunctionName(op, from: narrow, to: wide)
    let reference = referenceResult(
        referenceCall(function, referenceArguments),
        returning: .vector,
        for: wide
    )
    let suffix = guarded ? " before a guard page" : ""
    let countLabel = constantCount ? " with count \\(count)" : ""
    return referenceTestFunction(
        test,
        label: "\(op.swiftName) from \(narrow.swiftType)\(countLabel)\(suffix)",
        for: wide,
        inputs: inputs,
        signature: constantCount ? constantHelperSignature(test, "count", "Int") : nil,
        statements: referenceLoadStatements(
            of: "from",
            aligned: false,
            guardedLanes: guarded ? guardedLanes(of: "from", extent: op.span) : nil,
            port: "unsafe \(portCall(op.swiftName, portArguments))",
            reference: "unsafe \(reference)",
            description: referenceDescription(of: inputs)
        )
    )
}

func repeatingBlockReferenceTest(for element: Element) -> String {
    let seed = "seed: \(referenceTestSeed(element, repeatingBlockName, "0"))"
    let vectors = ReferenceInput(
        parameter: .vector,
        name: "vector",
        values: "Inputs.vectors(H.Vector.self, \(seed))"
    )
    let lanes = repeatingBlockLanes(of: element).indices.map {
        "\(simdVector("vector", of: element))[\($0)]"
    }
    let function = referenceFunctionName(repeatingBlockName, element)
    let port = portCall(repeatingBlockName, lanes)
    let reference = referenceResult(
        referenceCall(function, lanes),
        returning: .vector,
        for: element
    )
    let description = "\"lanes: \\(describe(vector))\""
    return referenceTestFunction(
        repeatingBlockName,
        label: repeatingBlockName,
        for: element,
        inputs: [vectors],
        statements: "mismatches.check(\(port), \(reference), \(description))"
    )
}

func canLookupReferenceTest(_ size: LookupSize, for element: Element) -> String {
    let name = canLookupName(size.lanes)
    let call = referenceCall(referenceFunctionName(name, element), [])
    return referenceTestFunction(
        name,
        label: name,
        for: element,
        inputs: [],
        statements: "mismatches.check(H.\(name), \(call), \"\")"
    )
}

func laneCountReferenceTest(for element: Element) -> String {
    let call = referenceCall(referenceFunctionName("laneCount", element), [])
    return referenceTestFunction(
        "laneCount",
        label: "laneCount",
        for: element,
        inputs: [],
        statements: "mismatches.check(H.laneCount, \(call), \"\")"
    )
}

func simdVector(_ expression: String, of element: Element) -> String {
    element.hasOpaqueVector ? "\(expression).simd" : expression
}

func opaqueVector(_ expression: String, of element: Element, on type: String = "H") -> String {
    element.hasOpaqueVector ? "\(type).Vector(raw: \(expression))" : expression
}

func referenceConformances(of element: Element) -> String {
    let mask = "extension \(element.namespace).Mask: ReferenceMask {}"
    guard element.hasOpaqueVector else { return mask }
    return "extension \(element.namespace).Vector: ReferenceVector {}\n\n\(mask)"
}

func generateReferenceTests(_ element: Element) -> String {
    var tests = [laneCountReferenceTest(for: element)]
    for size in lookupSizes where size.applies.matches(element) {
        tests.append(canLookupReferenceTest(size, for: element))
    }
    for op in ops where op.applies.matches(element) {
        tests.append(referenceTest(of: op, for: element, inContract: true))
        if takesIndices(op) {
            tests.append(referenceTest(of: op, for: element, inContract: true, checked: false))
        }
        if hasOutOfContractInputs(op) {
            tests.append(
                referenceTest(of: op, for: element, inContract: false, checked: !takesIndices(op))
            )
        }
        if op.span != nil {
            tests.append(referenceTest(of: op, for: element, inContract: true, guarded: true))
        }
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            tests.append(wideningReferenceTest(op, from: narrow, to: element))
            tests.append(wideningReferenceTest(op, from: narrow, to: element, guarded: true))
        }
    }
    tests.append(repeatingBlockReferenceTest(for: element))

    return """
        \(generationNotice)

        import CHighwayReference
        import Vectorization
        import Testing

        \(referenceConformances(of: element))

        @Suite("\(element.namespace) against Highway")
        struct \(element.namespace)ReferenceTests {
            typealias H = \(element.namespace)

        \(tests.joined(separator: "\n\n"))
        }

        """
}

let targetReferenceChecks: [(test: String, port: String, reference: String)] = [
    (
        "targetName",
        "SIMDTarget.targetName",
        "unsafe String(cString: \(referenceCall("targetName", [])))"
    ),
    ("isEmulated", "SIMDTarget.isEmulated", referenceCall("isEmulated", [])),
]

func generateReferenceTargetTests() -> String {
    let tests = targetReferenceChecks.map { test, port, reference in
        """
        @Test func \(test)() {
        let mismatches = Mismatches("\(test)")
        mismatches.check(\(port), \(reference), "")
        mismatches.record()
        }
        """
    }

    return """
        \(generationNotice)

        import CHighwayReference
        import Vectorization
        import Testing

        @Suite("HighwayTarget against Highway")
        struct HighwayTargetReferenceTests {
        \(tests.joined(separator: "\n\n"))
        }

        """
}

func uppercasedFirst(_ text: String) -> String {
    "\(text.prefix(1).uppercased())\(text.dropFirst())"
}

func codegenConstantSuffix(_ constantParameter: String?) -> String {
    constantParameter.map { "Constant\(uppercasedFirst($0))" } ?? ""
}

func codegenFunctionName(
    _ side: String,
    _ referenceName: String,
    constantParameter: String? = nil
) -> String {
    "\(side)\(uppercasedFirst(referenceName))\(codegenConstantSuffix(constantParameter))"
}

func codegenFunction(
    _ name: String,
    parameters: [String],
    returnClause: String,
    call: String
) -> String {
    """
    @inline(never)
    public func \(name)(\(parameters.joined(separator: ", ")))\(returnClause) {
        \(call)
    }
    """
}

func codegenFunctions(
    _ swiftName: String,
    referenceName: String,
    for element: Element,
    returns: ReturnType,
    isUnsafe: (port: Bool, reference: Bool),
    constantParameter: String? = nil,
    port: (parameters: [String], arguments: [String]),
    reference: (parameters: [String], arguments: [String])
) -> String {
    let portKeyword = isUnsafe.port ? "unsafe " : ""
    let referenceKeyword = isUnsafe.reference ? "unsafe " : ""
    let hasReturn = returns != .void
    let portReturn = swiftReturnType(returns, scope: "\(element.namespace).")
    let referenceReturn = importedReturnType(returns, element)
    let functions = [
        codegenFunction(
            codegenFunctionName("port", referenceName, constantParameter: constantParameter),
            parameters: port.parameters,
            returnClause: hasReturn ? " -> \(portReturn)" : "",
            call: portKeyword + portCall(swiftName, port.arguments, on: element.namespace)
        ),
        codegenFunction(
            codegenFunctionName("highway", referenceName, constantParameter: constantParameter),
            parameters: reference.parameters,
            returnClause: hasReturn ? " -> \(referenceReturn)" : "",
            call: referenceKeyword
                + referenceResult(
                    referenceCall(
                        referenceName,
                        reference.arguments,
                        in: referenceNothrowNamespace
                    ),
                    returning: returns,
                    for: element,
                    on: element.namespace
                )
        ),
    ]
    return functions.joined(separator: "\n\n")
}

struct CodegenParameter {
    let binding: Binding
    let kind: Parameter
    let referenceType: String
}

func codegenBinding(label: String, name: String, type: String) -> Binding {
    Binding(
        declaration: "",
        cDeclaration: "",
        argument: name,
        swiftLabel: label,
        swiftName: name,
        swiftType: type,
        isInOut: false
    )
}

struct CodegenSide {
    enum Kind: String {
        case port
        case highway
    }

    let kind: Kind
    let element: Element

    var vector: String { returnType(.vector) }
    var lane: String { returnType(.lane) }
    var pointer: String { "UnsafePointer<\(lane)>" }

    var namespace: String {
        switch kind {
        case .port: return element.namespace
        case .highway: return referenceNamespace(of: element)
        }
    }

    var laneCount: String { "\(namespace).laneCount" }

    func returnType(_ returns: ReturnType) -> String {
        switch kind {
        case .port: return swiftReturnType(returns, scope: "\(element.namespace).")
        case .highway: return importedReturnType(returns, element)
        }
    }

    func call(_ identifier: String, _ arguments: [String]) -> String {
        let op = codegenOp(identifier, for: element)
        let operandBindings = bindings(of: op, for: element, checked: !takesIndices(op))
        let callBindings = zip(operandBindings, op.parameters)
            .filter { _, parameter in parameter != .tag }
            .map(\.0)
        guard callBindings.count == arguments.count else {
            fatalError(
                "\(identifier) takes \(callBindings.count) arguments, not \(arguments.count)"
            )
        }
        let keyword = isUnsafe(op) ? "unsafe " : ""
        switch kind {
        case .port:
            let labelled = zip(op.swiftOrdered(callBindings), arguments).map {
                swiftCallArgument($0, passing: $1)
            }
            let portKeyword = isUnsafe(op) || takesIndices(op) ? "unsafe " : ""
            return portKeyword + portCall(op.swiftName, labelled, on: element.namespace)
        case .highway:
            let converted = zip(op.swiftOrdered(op.operands), arguments).map {
                rawArgument($1, $0, for: element)
            }
            let reference = referenceFunctionName(op.identifier, element)
            let call = referenceCall(
                reference,
                op.highwayOrdered(converted),
                in: referenceNothrowNamespace
            )
            return keyword
                + referenceResult(call, returning: op.returns, for: element, on: element.namespace)
        }
    }

    func repeating(_ value: String) -> String {
        call("repeating", [value])
    }

    func repeatingBlock(_ lanes: [String]) -> String {
        switch kind {
        case .port:
            return portCall(repeatingBlockName, lanes, on: element.namespace)
        case .highway:
            let call = referenceCall(
                referenceFunctionName(repeatingBlockName, element),
                lanes,
                in: referenceNothrowNamespace
            )
            return referenceResult(call, returning: .vector, for: element, on: element.namespace)
        }
    }
}

func codegenOp(_ identifier: String, for element: Element) -> Op {
    guard let op = ops.first(where: { $0.identifier == identifier && $0.applies.matches(element) })
    else {
        fatalError("\(identifier) is not an op of \(element.swiftType)")
    }
    return op
}

func codegenConstant(
    of parameter: Parameter,
    for element: Element
) -> (port: String, reference: String)? {
    let port = CodegenSide(kind: .port, element: element)
    let highway = CodegenSide(kind: .highway, element: element)
    let lane = element.category == .float ? "1.5" : "26"
    switch parameter {
    case .vector, .fillVector, .otherwiseVector:
        return (port.repeating(lane), highway.repeating(lane))
    case .indices: return (port.repeating("3"), highway.repeating("3"))
    case .laneIndices, .lookupIndices:
        let indices = laneIndexElement(of: element)
        return (
            CodegenSide(kind: .port, element: indices).repeating("1"),
            CodegenSide(kind: .highway, element: indices).repeating("1")
        )
    case .lane, .fillLane: return (lane, lane)
    case .shiftAmount: return ("3", "3")
    case .laneAmount, .count: return ("1", "1")
    case .tag, .mask, .whereMask, .constLanePointer, .lanePointer, .outVector: return nil
    }
}

func codegenVariants(of parameters: [CodegenParameter], for element: Element) -> [Int?] {
    let constants = parameters.indices.filter {
        codegenConstant(of: parameters[$0].kind, for: element) != nil
    }
    return [nil] + constants
}

func codegenFunctions(
    _ swiftName: String,
    referenceName: String,
    for element: Element,
    returns: ReturnType,
    isUnsafe: (port: Bool, reference: Bool),
    parameters: [CodegenParameter],
    highwayOrdered: ([String]) -> [String] = { $0 }
) -> String {
    var functions: [String] = []

    for variant in codegenVariants(of: parameters, for: element) {
        var portParameters: [String] = []
        var referenceParameters: [String] = []
        var portArguments: [String] = []
        var referenceArguments: [String] = []

        for (index, parameter) in parameters.enumerated() {
            let binding = parameter.binding
            if index == variant, let constant = codegenConstant(of: parameter.kind, for: element) {
                portArguments.append(swiftCallArgument(binding, passing: constant.port))
                referenceArguments.append(
                    rawArgument(constant.reference, parameter.kind, for: element)
                )
                continue
            }
            let isShiftAmount = parameter.kind == .shiftAmount
            portParameters.append(swiftDeclaration(binding, as: isShiftAmount ? "Int32" : nil))
            referenceParameters.append(swiftDeclaration(binding, as: parameter.referenceType))
            portArguments.append(
                swiftCallArgument(
                    binding,
                    passing: isShiftAmount ? "Int(\(binding.swiftName))" : nil
                )
            )
            referenceArguments.append(
                rawArgument(binding.swiftName, parameter.kind, for: element)
            )
        }

        functions.append(
            codegenFunctions(
                swiftName,
                referenceName: referenceName,
                for: element,
                returns: returns,
                isUnsafe: isUnsafe,
                constantParameter: variant.map { parameters[$0].binding.swiftName },
                port: (portParameters, portArguments),
                reference: (referenceParameters, highwayOrdered(referenceArguments))
            )
        )
    }

    return functions.joined(separator: "\n\n")
}

func codegenParameters(of op: Op, for element: Element) -> [CodegenParameter] {
    var parameters: [CodegenParameter] = []

    let parameterBindings = bindings(
        of: op,
        for: element,
        scope: "\(element.namespace).",
        checked: false
    )
    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        if case .tag = parameter { continue }
        parameters.append(
            CodegenParameter(
                binding: binding,
                kind: parameter,
                referenceType: importedType(of: parameter, for: element)
            )
        )
    }

    return op.swiftOrdered(parameters)
}

func codegenFunctions(of op: Op, for element: Element) -> String {
    codegenFunctions(
        op.swiftName,
        referenceName: referenceFunctionName(op.identifier, element),
        for: element,
        returns: op.returns,
        isUnsafe: (port: isUnsafe(op) || hasCheckedForms(op), reference: isUnsafe(op)),
        parameters: codegenParameters(of: op, for: element),
        highwayOrdered: op.highwayOrdered
    )
}

func codegenParameters(of op: WideningOp, from narrow: Element) -> [CodegenParameter] {
    let pointerType = importedType(of: .constLanePointer, for: narrow)
    var parameters = [
        CodegenParameter(
            binding: codegenBinding(label: "from", name: "from", type: pointerType),
            kind: .constLanePointer,
            referenceType: pointerType
        )
    ]
    if op.takesCount {
        let countType = importedType(of: .count, for: narrow)
        parameters.append(
            CodegenParameter(
                binding: codegenBinding(label: "count", name: "count", type: countType),
                kind: .count,
                referenceType: countType
            )
        )
    }
    return parameters
}

func codegenFunctions(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    codegenFunctions(
        op.swiftName,
        referenceName: wideningFunctionName(op, from: narrow, to: wide),
        for: wide,
        returns: .vector,
        isUnsafe: (port: true, reference: true),
        parameters: codegenParameters(of: op, from: narrow)
    )
}

func repeatingBlockCodegenFunctions(for element: Element) -> String {
    let lanes = repeatingBlockLanes(of: element)
    return codegenFunctions(
        repeatingBlockName,
        referenceName: referenceFunctionName(repeatingBlockName, element),
        for: element,
        returns: .vector,
        isUnsafe: (port: false, reference: false),
        port: (lanes.map { "_ \($0): \(element.namespace).Lane" }, lanes),
        reference: (lanes.map { "_ \($0): \(element.swiftType)" }, lanes)
    )
}

func referenceNamespace(of element: Element) -> String {
    "HighwayReference\(element.swiftType)"
}

func referenceSpanForms(of op: Op, for element: Element) -> SpanForms? {
    guard var forms = spanForms(of: op, for: element) else { return nil }
    forms.count = "\(referenceNothrowNamespace).spanCount($0.count, laneCount)"
    let parameterBindings = bindings(of: op, for: element)
    let takesCountFromSpan = if case .first = forms.extent { true } else { false }
    forms.bridgeCall = { pointer, count in
        var arguments: [String] = []
        for (binding, parameter) in zip(parameterBindings, op.parameters) {
            switch parameter {
            case .tag:
                continue
            case .count where takesCountFromSpan:
                arguments.append(count)
            case .constLanePointer, .lanePointer:
                arguments.append(pointer)
            default:
                arguments.append(rawArgument(binding.swiftName, parameter, for: element))
            }
        }
        let call = referenceCall(
            referenceFunctionName(op.identifier, element),
            arguments,
            in: referenceNothrowNamespace
        )
        let result = referenceResult(
            call,
            returning: op.returns,
            for: element,
            on: element.namespace
        )
        return "unsafe \(result)"
    }
    return forms
}

func referenceSpanForms(of op: WideningOp, from narrow: Element, to wide: Element) -> SpanForms {
    var forms = spanForms(of: op, from: narrow, to: wide)
    forms.count = "\(referenceNothrowNamespace).spanCount($0.count, laneCount)"
    let function = wideningFunctionName(op, from: narrow, to: wide)
    forms.bridgeCall = { pointer, count in
        let call = referenceCall(
            function,
            op.takesCount ? [pointer, count] : [pointer],
            in: referenceNothrowNamespace
        )
        return "unsafe \(referenceResult(call, returning: .vector, for: wide, on: wide.namespace))"
    }
    return forms
}

/// Highway's ops behind the same span members as the port's, so that kernels take spans on both
/// sides.
func referenceSpanNamespace(of element: Element) -> String {
    var output = """
        public enum \(referenceNamespace(of: element)) {
            public typealias Lane = \(element.swiftType)
            public typealias Vector = \(element.namespace).Vector

            @export(implementation) @inline(always)
            public static var laneCount: Int {
                Int(\(referenceCall(referenceFunctionName("laneCount", element), [], in: referenceNothrowNamespace)))
            }


        """
    for op in ops where op.applies.matches(element) && !takesLookupIndices(op) {
        guard let forms = referenceSpanForms(of: op, for: element) else { continue }
        output += spanMembers(forms)
        if forms.isMutable {
            output += outputSpanMembers(forms)
        }
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            output += spanMembers(referenceSpanForms(of: op, from: narrow, to: element))
        }
    }
    output += "}\n"
    return output
}

struct KernelParameter {
    enum Kind {
        case vector
        case lane
        case pointer
        case count
        case span
        case byteSpan
        case outputSpan
    }

    let label: String
    let name: String
    let kind: Kind

    func type(on side: CodegenSide) -> String {
        switch kind {
        case .vector: return side.vector
        case .lane: return side.lane
        case .pointer: return side.pointer
        case .count: return "Int"
        case .span: return "Span<\(side.lane)>"
        case .byteSpan: return "Span<UInt8>"
        case .outputSpan: return "inout OutputSpan<\(side.lane)>"
        }
    }

    func declaration(on side: CodegenSide) -> String {
        let naming = label == name ? name : "\(label) \(name)"
        return "\(naming): \(type(on: side))"
    }

    func argument(passing expression: String) -> String {
        label == "_" ? expression : "\(label): \(expression)"
    }
}

struct CodegenKernel {
    let name: String
    let applies: Applies
    let returns: ReturnType
    let parameters: [KernelParameter]
    let body: (CodegenSide) -> String
    var usesSpans = false
}

func codegenBlockLoop(on side: CodegenSide, block: [String], remainder: [String]) -> String {
    """
    let laneCount = \(side.laneCount)
    var from = unsafe from
    var count = count
    while count >= laneCount {
    \(block.joined(separator: "\n"))
    unsafe from += laneCount
    count -= laneCount
    }
    if count > 0 {
    \(remainder.joined(separator: "\n"))
    }
    """
}

func codegenDigitValues(
    of vector: String,
    on side: CodegenSide
) -> (statements: [String], result: String) {
    let lettersExpression = side.call("subtracting", [vector, side.repeating("0x61")])
    let fromZero = side.call("subtracting", [vector, side.repeating("0x30")])
    let clamped = side.call("minimum", [fromZero, side.repeating("36")])
    let numbersExpression = side.call("adding", [clamped, side.repeating("26")])
    let isLetter = side.call("lessThan", ["letters", side.repeating("26")])
    return (
        ["let letters = \(lettersExpression)", "let numbers = \(numbersExpression)"],
        side.call("selecting", [isLetter, "letters", "numbers"])
    )
}

let utf8LookupTables: [(name: String, lanes: [Int])] = [
    ("byte1High", [2, 2, 2, 2, 2, 2, 2, 2, 128, 128, 128, 128, 33, 1, 21, 73]),
    ("byte1Low", [231, 163, 131, 131, 139, 203, 203, 203, 203, 203, 203, 203, 203, 219, 203, 203]),
    ("byte2High", [1, 1, 1, 1, 1, 1, 1, 1, 230, 174, 186, 186, 1, 1, 1, 1]),
]

func codegenSpanAdvance(_ span: String, by count: String, range: String) -> String {
    """
    let \(range) = unsafe Range<Int>(uncheckedBounds: (\(count), \(span).count))
    \(span) = unsafe \(span).extracting(unchecked: \(range))
    """
}

func codegenUTF8LookupErrors(on side: CodegenSide) -> (statements: [String], result: String) {
    let byte1High = side.call(
        "tableLookupBytes",
        ["byte1High", side.call("shiftedRight", ["prev1", "4"])]
    )
    let byte1Low = side.call(
        "tableLookupBytes",
        ["byte1Low", side.call("bitwiseAnd", ["prev1", side.repeating("0x0F")])]
    )
    let byte2High = side.call(
        "tableLookupBytes",
        ["byte2High", side.call("shiftedRight", ["input", "4"])]
    )
    let specialCases = side.call(
        "bitwiseAnd",
        [side.call("bitwiseAnd", [byte1High, byte1Low]), byte2High]
    )
    let continuations = side.call(
        "bitwiseOr",
        [
            side.call("saturatingSubtracting", ["prev2", side.repeating("0xE0 &- 0x80")]),
            side.call("saturatingSubtracting", ["prev3", side.repeating("0xF0 &- 0x80")]),
        ]
    )
    let mustBe23Continuation = side.call("bitwiseAnd", [continuations, side.repeating("0x80")])
    return (
        [
            "let specialCases = \(specialCases)",
            "let mustBe23Continuation = \(mustBe23Continuation)",
        ],
        side.call("bitwiseXor", ["mustBe23Continuation", "specialCases"])
    )
}

func codegenUTF8LookupWindow(
    of span: String,
    loading name: String,
    label: String,
    on side: CodegenSide
) -> [String] {
    var statements = ["let windowCount = \(span).count"]
    for (vector, offset) in [("input", 3), ("prev1", 2), ("prev2", 1)] {
        let window =
            "\(span).extracting(unchecked: Range(uncheckedBounds: (\(offset), windowCount)))"
        statements.append("let \(vector) = unsafe \(side.namespace).\(name)(\(label): \(window))")
    }
    let keyword = label == "fromUnchecked" ? "unsafe " : ""
    statements.append("let prev3 = \(keyword)\(side.namespace).\(name)(\(label): \(span))")
    return statements
}

let codegenKernels: [CodegenKernel] = [
    CodegenKernel(
        name: "MaskedLowercase",
        applies: .integer(bits: [8]),
        returns: .vector,
        parameters: [KernelParameter(label: "_", name: "v", kind: .vector)],
        body: { side in
            let offset = side.call("subtracting", ["v", side.repeating("0x41")])
            let isUppercase = side.call("lessThan", [offset, side.repeating("26")])
            let lowercaseBit = side.call("selectingOrZero", [isUppercase, side.repeating("0x20")])
            return "return \(side.call("bitwiseOr", ["v", lowercaseBit]))"
        }
    ),
    CodegenKernel(
        name: "DigitValues",
        applies: .unsigned(bits: [8]),
        returns: .vector,
        parameters: [KernelParameter(label: "_", name: "v", kind: .vector)],
        body: { side in
            let digits = codegenDigitValues(of: "v", on: side)
            return (digits.statements + ["return \(digits.result)"]).joined(separator: "\n")
        }
    ),
    CodegenKernel(
        name: "NoneAbove",
        applies: .integer,
        returns: .boolean,
        parameters: [KernelParameter(label: "_", name: "v", kind: .vector)],
        body: { side in
            let above = side.call("greaterThan", ["v", side.repeating("26")])
            return "return \(side.call("allFalse", [above]))"
        }
    ),
    CodegenKernel(
        name: "SmallestAtLeast",
        applies: .unsigned(bits: [32]),
        returns: .lane,
        parameters: [
            KernelParameter(label: "from", name: "from", kind: .pointer),
            KernelParameter(label: "count", name: "count", kind: .count),
            KernelParameter(label: "atLeast", name: "n", kind: .lane),
        ],
        body: { side in
            let candidates = side.call(
                "selecting",
                [side.call("lessThan", ["loaded", "threshold"]), "identity", "loaded"]
            )
            let accumulate = "accumulator = \(side.call("minimum", ["accumulator", candidates]))"
            let blockLoad = "let loaded = \(side.call("load", ["from"]))"
            let remainderLoad = "let loaded = \(side.call("loadFirst", ["from", "count"]))"
            let loop = codegenBlockLoop(
                on: side,
                block: [blockLoad, accumulate],
                remainder: [remainderLoad, accumulate]
            )
            return """
                let identity = \(side.repeating(".max"))
                let threshold = \(side.repeating("n"))
                var accumulator = identity
                \(loop)
                return \(side.call("smallest", ["accumulator"]))
                """
        }
    ),
    CodegenKernel(
        name: "LargestDigit",
        applies: .unsigned(bits: [8]),
        returns: .boolean,
        parameters: [
            KernelParameter(label: "from", name: "from", kind: .pointer),
            KernelParameter(label: "count", name: "count", kind: .count),
        ],
        body: { side in
            let digits = codegenDigitValues(of: "loaded", on: side)
            let blockLoad = "let loaded = \(side.call("load", ["from"]))"
            let blockMaximum = "largest = \(side.call("maximum", ["largest", digits.result]))"
            let remainderLoad = "let loaded = \(side.call("loadFirst", ["from", "count"]))"
            let remainderDigits = side.call(
                "selectingOrZero",
                [side.call("firstLanes", ["count"]), digits.result]
            )
            let remainderMaximum = "largest = \(side.call("maximum", ["largest", remainderDigits]))"
            let loop = codegenBlockLoop(
                on: side,
                block: [blockLoad] + digits.statements + [blockMaximum],
                remainder: [remainderLoad] + digits.statements + [remainderMaximum]
            )
            let aboveDigits = side.call("greaterThan", ["largest", side.repeating("35")])
            return """
                var largest = \(side.call("zero", []))
                \(loop)
                return \(side.call("allFalse", [aboveDigits]))
                """
        }
    ),
    CodegenKernel(
        name: "UTF8LookupStep",
        applies: .unsigned(bits: [8]),
        returns: .vector,
        parameters: [KernelParameter(label: "_", name: "input", kind: .vector)],
        body: { side in
            let tables = utf8LookupTables.map { table in
                "let \(table.name) = \(side.repeatingBlock(table.lanes.map(String.init)))"
            }
            let slides = [
                "let prev1 = \(side.call("slide1Up", ["input"]))",
                "let prev2 = \(side.call("slideUpLanes", ["input", "2"]))",
                "let prev3 = \(side.call("slideUpLanes", ["input", "3"]))",
            ]
            let prev1High = side.call(
                "tableLookupBytes",
                ["byte1High", side.call("shiftedRight", ["prev1", "4"])]
            )
            let prev1Low = side.call(
                "tableLookupBytes",
                ["byte1Low", side.call("bitwiseAnd", ["prev1", side.repeating("0x0F")])]
            )
            let inputHigh = side.call(
                "tableLookupBytes",
                ["byte2High", side.call("shiftedRight", ["input", "4"])]
            )
            let special = side.call(
                "bitwiseAnd",
                [side.call("bitwiseAnd", [prev1High, prev1Low]), inputHigh]
            )
            let continuations = side.call(
                "bitwiseOr",
                [
                    side.call("saturatingSubtracting", ["prev2", side.repeating("0x60")]),
                    side.call("saturatingSubtracting", ["prev3", side.repeating("0x70")]),
                ]
            )
            let result = side.call("bitwiseXor", [special, continuations])
            return (tables + slides + ["return \(result)"]).joined(separator: "\n")
        }
    ),
    CodegenKernel(
        name: "SmallestAtLeastSpan",
        applies: .unsigned(bits: [32]),
        returns: .lane,
        parameters: [
            KernelParameter(label: "atLeast", name: "n", kind: .lane),
            KernelParameter(label: "in", name: "values", kind: .span),
        ],
        body: { side in
            let isBelow = "let isBelow = \(side.call("lessThan", ["loaded", "threshold"]))"
            let candidates = side.call("selecting", ["isBelow", "identity", "loaded"])
            let accumulate = "accumulator = \(side.call("minimum", ["accumulator", candidates]))"
            let advance = codegenSpanAdvance(
                "remainingValuesSpan",
                by: "laneCount",
                range: "remainingValuesRange"
            )
            return """
                let laneCount = \(side.laneCount)
                let identity = \(side.repeating(".max"))
                let threshold = \(side.repeating("n"))
                var accumulator = identity

                var remainingValuesSpan = values
                while remainingValuesSpan.count >= laneCount {
                let loaded = \(side.namespace).load(from: remainingValuesSpan)
                \(isBelow)
                \(accumulate)
                \(advance)
                }
                if !remainingValuesSpan.isEmpty {
                let loaded = \(side.namespace).loadFirst(from: remainingValuesSpan)
                \(isBelow)
                \(accumulate)
                }
                return \(side.call("smallest", ["accumulator"]))
                """
        },
        usesSpans: true
    ),
    CodegenKernel(
        name: "LargestDigitSpan",
        applies: .unsigned(bits: [8]),
        returns: .boolean,
        parameters: [KernelParameter(label: "_", name: "inputBytesSpan", kind: .span)],
        body: { side in
            let digits = codegenDigitValues(of: "loaded", on: side)
            let firstDigits = side.call(
                "selectingOrZero",
                [side.call("firstLanes", ["remaining"]), digits.result]
            )
            let advance = codegenSpanAdvance(
                "remainingBytesSpan",
                by: "laneCount",
                range: "remainingBytesRange"
            )
            let aboveDigits = side.call("greaterThan", ["largestDigit", side.repeating("35")])
            return """
                let count = inputBytesSpan.count
                guard count > 0 else {
                return true
                }

                let laneCount = \(side.laneCount)
                var remainingBytesSpan = inputBytesSpan
                var largestDigit = \(side.call("zero", []))
                while remainingBytesSpan.count >= laneCount {
                let loaded = \(side.namespace).load(from: remainingBytesSpan)
                \(digits.statements.joined(separator: "\n"))
                largestDigit = \(side.call("maximum", ["largestDigit", digits.result]))
                \(advance)
                }
                if !remainingBytesSpan.isEmpty {
                let remaining = remainingBytesSpan.count
                let loaded = \(side.namespace).loadFirst(from: remainingBytesSpan)
                \(digits.statements.joined(separator: "\n"))
                largestDigit = \(side.call("maximum", ["largestDigit", firstDigits]))
                }
                return \(side.call("allFalse", [aboveDigits]))
                """
        },
        usesSpans: true
    ),
    CodegenKernel(
        name: "MaskedLowercaseSpan",
        applies: .unsigned(bits: [8]),
        returns: .count,
        parameters: [
            KernelParameter(label: "span", name: "span", kind: .span),
            KernelParameter(label: "into", name: "output", kind: .outputSpan),
        ],
        body: { side in
            let isASCII = side.call(
                "allFalse",
                [side.call("greaterThan", ["window", side.repeating("0x7F")])]
            )
            let isUppercasedLetter = side.call(
                "lessThan",
                [
                    side.call("subtracting", ["window", side.repeating("0x41")]),
                    side.repeating("26"),
                ]
            )
            let lowercaseBit = side.call(
                "selectingOrZero",
                ["isUppercasedLetter", side.repeating("0b0010_0000")]
            )
            let advance = codegenSpanAdvance(
                "remainingBytesSpan",
                by: "windowLength",
                range: "remainingBytesRange"
            )
            return """
                let laneCount = \(side.laneCount)
                var remainingBytesSpan = span
                while !remainingBytesSpan.isEmpty {
                let windowLength = min(laneCount, remainingBytesSpan.count)
                let window =
                if windowLength == laneCount {
                \(side.namespace).load(from: remainingBytesSpan)
                } else {
                \(side.namespace).loadFirst(from: remainingBytesSpan)
                }
                if \(isASCII) {
                let isUppercasedLetter = \(isUppercasedLetter)
                let lowercased = \(side.call("bitwiseOr", ["window", lowercaseBit]))
                if windowLength == laneCount {
                unsafe \(side.namespace).append(lowercased, toUnchecked: &output)
                } else {
                unsafe \(side.namespace).append(
                lowercased,
                addingCount: windowLength,
                toUnchecked: &output
                )
                }
                \(advance)
                continue
                }
                break
                }
                return remainingBytesSpan.count
                """
        },
        usesSpans: true
    ),
    CodegenKernel(
        name: "UTF8LookupSpan",
        applies: .unsigned(bits: [8]),
        returns: .boolean,
        parameters: [KernelParameter(label: "_", name: "bytes", kind: .span)],
        body: { side in
            let tables = utf8LookupTables.map { table in
                "let \(table.name) = \(side.repeatingBlock(table.lanes.map(String.init)))"
            }
            let errors = codegenUTF8LookupErrors(on: side)
            let head = [
                "let input = headBytes",
                "let prev1 = \(side.call("slide1Up", ["headBytes"]))",
                "let prev2 = \(side.call("slideUpLanes", ["headBytes", "2"]))",
                "let prev3 = \(side.call("slideUpLanes", ["headBytes", "3"]))",
            ]
            let window = codegenUTF8LookupWindow(
                of: "remainingBytesSpan",
                loading: "load",
                label: "fromUnchecked",
                on: side
            )
            let lastWindow = codegenUTF8LookupWindow(
                of: "remainingBytesSpan",
                loading: "loadFirst",
                label: "from",
                on: side
            )
            let accumulate = "errors = \(side.call("bitwiseOr", ["errors", errors.result]))"
            let advance = codegenSpanAdvance(
                "remainingBytesSpan",
                by: "laneCount",
                range: "remainingBytesRange"
            )
            let hasErrors = side.call("notEqualTo", ["errors", side.call("zero", [])])
            return """
                let count = bytes.count
                guard count > 0 else {
                return true
                }

                let laneCount = \(side.laneCount)
                guard _fastPath(laneCount >= 16) else {
                return false
                }

                \(tables.joined(separator: "\n"))
                let headBytes = \(side.namespace).loadFirst(from: bytes)
                \((head + errors.statements).joined(separator: "\n"))
                var errors = \(errors.result)

                if count > laneCount {
                var remainingBytesSpan = unsafe bytes.extracting(
                unchecked: Range<Int>(uncheckedBounds: (laneCount &- 3, count))
                )
                while remainingBytesSpan.count >= laneCount &+ 3 {
                \((window + errors.statements).joined(separator: "\n"))
                \(accumulate)
                \(advance)
                }
                if remainingBytesSpan.count > 3 {
                \((lastWindow + errors.statements).joined(separator: "\n"))
                \(accumulate)
                }
                }

                if count >= 3 {
                let last = unsafe bytes[unchecked: count &- 1]
                let secondToLast = unsafe bytes[unchecked: count &- 2]
                let thirdToLast = unsafe bytes[unchecked: count &- 3]
                if last >= 0xC0 || secondToLast >= 0xE0 || thirdToLast >= 0xF0 {
                return false
                }
                }

                return \(side.call("allFalse", [hasErrors]))
                """
        },
        usesSpans: true
    ),
    CodegenKernel(
        name: "SumWideningSpan",
        applies: .unsigned(bits: [32]),
        returns: .lane,
        parameters: [KernelParameter(label: "_", name: "bytes", kind: .byteSpan)],
        body: { side in
            let advance = codegenSpanAdvance(
                "remainingBytesSpan",
                by: "laneCount",
                range: "remainingBytesRange"
            )
            let widened = "\(side.namespace).loadWidening(from: remainingBytesSpan)"
            let firstWidened = "\(side.namespace).loadFirstWidening(from: remainingBytesSpan)"
            return """
                let laneCount = \(side.laneCount)
                var total = \(side.call("zero", []))
                var remainingBytesSpan = bytes
                while remainingBytesSpan.count >= laneCount {
                total = \(side.call("adding", ["total", widened]))
                \(advance)
                }
                if !remainingBytesSpan.isEmpty {
                total = \(side.call("adding", ["total", firstWidened]))
                }
                return \(side.call("sum", ["total"]))
                """
        },
        usesSpans: true
    ),
]

func codegenKernelFunctions(_ kernel: CodegenKernel, for element: Element) -> String {
    let referenceName = referenceFunctionName(kernel.name, element)
    let functions = [CodegenSide.Kind.port, .highway].map { kind in
        let side = CodegenSide(kind: kind, element: element)
        let function = codegenFunction(
            codegenFunctionName(kind.rawValue, referenceName),
            parameters: kernel.parameters.map { $0.declaration(on: side) },
            returnClause: " -> \(side.returnType(kernel.returns))",
            call: kernel.body(side)
        )
        return kernel.usesSpans ? "\(spanAvailability)\n\(function)" : function
    }
    return functions.joined(separator: "\n\n")
}

func codegenCalls(
    of parameters: [CodegenParameter],
    for element: Element,
    referenceName: String,
    constant: Int?,
    keyword: String,
    pointer: String,
    highwayCount: String? = nil
) -> (port: String, reference: String) {
    var portArguments: [String] = []
    var referenceArguments: [String] = []
    var outVectorIndex = 0

    for (index, parameter) in parameters.enumerated() where index != constant {
        let binding = parameter.binding
        switch parameter.kind {
        case .tag:
            continue
        case .vector, .indices, .laneIndices, .lookupIndices, .mask, .fillVector, .whereMask,
            .otherwiseVector, .lane, .fillLane, .laneAmount:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append(swiftCallArgument(binding))
        case .count:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append(swiftCallArgument(binding, passing: highwayCount))
        case .shiftAmount:
            let amount = swiftArgument(binding, parameter.kind, for: element)
            portArguments.append(swiftCallArgument(binding, passing: amount))
            referenceArguments.append(swiftCallArgument(binding, passing: amount))
        case .constLanePointer, .lanePointer:
            portArguments.append(swiftCallArgument(binding, passing: pointer))
            referenceArguments.append(swiftCallArgument(binding, passing: pointer))
        case .outVector:
            portArguments.append(swiftCallArgument(binding, passing: "p\(outVectorIndex)"))
            referenceArguments.append(swiftCallArgument(binding, passing: "r\(outVectorIndex)"))
            outVectorIndex += 1
        }
    }

    let constantName = constant.map { parameters[$0].binding.swiftName }
    func call(_ side: String, _ arguments: [String]) -> String {
        let name = codegenFunctionName(side, referenceName, constantParameter: constantName)
        return "\(keyword)\(name)(\(arguments.joined(separator: ", ")))"
    }
    return (call("port", portArguments), call("highway", referenceArguments))
}

func codegenGuardedCount(
    of parameters: [CodegenParameter],
    for element: Element,
    constant: Int?
) -> String {
    guard let constant, parameters[constant].kind == .count,
        let value = codegenConstant(of: .count, for: element)
    else { return "count" }
    return value.port
}

func unorderedNaNsCondition(
    of op: Op,
    for element: Element,
    inputs: [ReferenceInput]
) -> String? {
    unorderedNaNsCondition(
        of: op,
        for: element,
        vectors: inputs.filter { $0.parameter == .vector }.map(\.name)
    )
}

func unorderedNaNsCondition(
    of op: Op,
    for element: Element,
    vectors: [String]
) -> String? {
    guard element.category == .float, let unorderedNaNs = op.unorderedNaNs else { return nil }
    switch (unorderedNaNs, vectors.count) {
    case (.perLane, 2), (.multiplyAdd, 2):
        return "!hasUnorderedNaNs(\(vectors.joined(separator: ", ")))"
    case (.multiplyAdd, 3):
        return "!hasUnorderedNaNs(multiplying: \(vectors[0]), \(vectors[1]), adding: \(vectors[2]))"
    case (.acrossLanes, 1):
        return "!hasUnorderedNaNs(lanesOf: \(vectors[0]))"
    default:
        return nil
    }
}

func codegenTest(
    of op: Op,
    for element: Element,
    constant: Int?,
    guarded: Bool = false
) -> String {
    let parameters = codegenParameters(of: op, for: element)
    let constantName = constant.map { parameters[$0].binding.swiftName }
    let name = "\(op.identifier)\(codegenConstantSuffix(constantName))"
    let test = guarded ? "\(name)BeforeGuardPage" : name
    let referenceName = referenceFunctionName(op.identifier, element)
    let function = codegenFunctionName("port", referenceName, constantParameter: constantName)
    let inputs = referenceInputs(of: op, for: element, test: test, inContract: true)
        .filter { $0.name != constantName }
    let calls = codegenCalls(
        of: parameters,
        for: element,
        referenceName: referenceName,
        constant: constant,
        keyword: isUnsafe(op) ? "unsafe " : "",
        pointer: referencePointer(of: op, guarded: guarded)
    )
    let (declarations, statements) = referenceStatements(
        of: op,
        for: element,
        inputs: inputs,
        guarded: guarded,
        count: codegenGuardedCount(of: parameters, for: element, constant: constant),
        calls: calls
    )

    return referenceTestFunction(
        test,
        label: guarded ? "\(function) before a guard page" : function,
        for: element,
        inputs: inputs,
        declarations: declarations,
        disabling: lookupDisabling(of: op),
        loopCondition: unorderedNaNsCondition(of: op, for: element, inputs: inputs),
        statements: statements
    )
}

func codegenWideningTest(
    _ op: WideningOp,
    from narrow: Element,
    to wide: Element,
    constant: Int?,
    guarded: Bool = false
) -> String {
    let parameters = codegenParameters(of: op, from: narrow)
    let constantName = constant.map { parameters[$0].binding.swiftName }
    let name = "\(op.swiftName)From\(narrow.swiftType)\(codegenConstantSuffix(constantName))"
    let test = guarded ? "\(name)BeforeGuardPage" : name
    let referenceName = wideningFunctionName(op, from: narrow, to: wide)
    let function = codegenFunctionName("port", referenceName, constantParameter: constantName)
    let seed = "seed: \(referenceTestSeed(wide, test, "0"))"
    var inputs = [
        ReferenceInput(
            parameter: .constLanePointer,
            name: "from",
            values: "Inputs.buffers(\(narrow.swiftType).self, count: H.laneCount, \(seed))"
        )
    ]
    if op.takesCount && constant == nil {
        inputs.append(
            ReferenceInput(
                parameter: .count,
                name: "count",
                values: "Inputs.bufferCounts(lanes: H.laneCount)"
            )
        )
    }
    let calls = codegenCalls(
        of: parameters,
        for: wide,
        referenceName: referenceName,
        constant: constant,
        keyword: "unsafe ",
        pointer: pointerExpression("source", aligned: guarded),
        highwayCount: guarded ? "min(count, H.laneCount)" : nil
    )
    let count = codegenGuardedCount(of: parameters, for: wide, constant: constant)

    return referenceTestFunction(
        test,
        label: guarded ? "\(function) before a guard page" : function,
        for: wide,
        inputs: inputs,
        statements: referenceLoadStatements(
            of: "from",
            aligned: false,
            guardedLanes: guarded ? guardedLanes(of: "from", extent: op.span, count: count) : nil,
            port: calls.port,
            reference: calls.reference,
            description: referenceDescription(of: inputs)
        )
    )
}

func codegenRepeatingBlockTest(for element: Element) -> String {
    let seed = "seed: \(referenceTestSeed(element, repeatingBlockName, "0"))"
    let vectors = ReferenceInput(
        parameter: .vector,
        name: "vector",
        values: "Inputs.vectors(H.Vector.self, \(seed))"
    )
    let lanes = repeatingBlockLanes(of: element).indices
        .map { "\(simdVector("vector", of: element))[\($0)]" }
        .joined(separator: ", ")
    let referenceName = referenceFunctionName(repeatingBlockName, element)
    let function = codegenFunctionName("port", referenceName)
    let port = "\(function)(\(lanes))"
    let reference = "\(codegenFunctionName("highway", referenceName))(\(lanes))"
    let description = "\"lanes: \\(describe(vector))\""
    return referenceTestFunction(
        repeatingBlockName,
        label: function,
        for: element,
        inputs: [vectors],
        statements: "mismatches.check(\(port), \(reference), \(description))"
    )
}

let codegenKernelLength = "3 * H.laneCount + 1"

func lowercasedFirstWord(_ name: String) -> String {
    let uppercase = name.prefix { $0.isUppercase }
    let followedByLowercase = name.dropFirst(uppercase.count).first?.isLowercase == true
    let count = max(uppercase.count - (followedByLowercase ? 1 : 0), 1)
    return name.prefix(count).lowercased() + name.dropFirst(count)
}

func codegenKernelInputs(
    of kernel: CodegenKernel,
    for element: Element,
    test: String
) -> [ReferenceInput] {
    var inputs: [ReferenceInput] = []
    let counts = "Inputs.counts(through: \(codegenKernelLength))"
    for parameter in kernel.parameters {
        let seed = "seed: \(referenceTestSeed(element, test, String(inputs.count)))"
        switch parameter.kind {
        case .vector:
            let values = "Inputs.vectors(H.Vector.self, \(seed))"
            inputs.append(ReferenceInput(parameter: .vector, name: parameter.name, values: values))
        case .lane:
            let values = "Inputs.lanes(H.Lane.self, \(seed))"
            inputs.append(ReferenceInput(parameter: .lane, name: parameter.name, values: values))
        case .pointer, .span, .byteSpan:
            let isBytes = element.bits == 8 || parameter.kind == .byteSpan
            let values =
                isBytes
                ? "Inputs.byteBuffers(count: \(codegenKernelLength), \(seed))"
                : "Inputs.buffers(H.Lane.self, count: \(codegenKernelLength), \(seed))"
            inputs.append(
                ReferenceInput(parameter: .constLanePointer, name: parameter.name, values: values)
            )
            if parameter.kind != .pointer {
                inputs.append(
                    ReferenceInput(
                        parameter: .count,
                        name: "\(parameter.name)Count",
                        values: counts
                    )
                )
            }
        case .count:
            inputs.append(ReferenceInput(parameter: .count, name: parameter.name, values: counts))
        case .outputSpan:
            continue
        }
    }
    return inputs.filter { $0.parameter != .lane } + inputs.filter { $0.parameter == .lane }
}

func codegenKernelTest(
    _ kernel: CodegenKernel,
    for element: Element,
    guarded: Bool = false
) -> String {
    let name = lowercasedFirstWord(kernel.name)
    let test = guarded ? "\(name)BeforeGuardPage" : name
    let referenceName = referenceFunctionName(kernel.name, element)
    let function = codegenFunctionName("port", referenceName)
    let inputs = codegenKernelInputs(of: kernel, for: element, test: test)
    let description = referenceDescription(of: inputs)
    let spans = kernel.parameters.filter { $0.kind == .span || $0.kind == .byteSpan }
    let pointer = kernel.parameters.first { $0.kind == .pointer }
    let arguments = kernel.parameters.map { parameter in
        switch parameter.kind {
        case .vector, .lane, .count: return parameter.argument(passing: parameter.name)
        case .pointer:
            return parameter.argument(passing: pointerExpression("source", aligned: guarded))
        case .span, .byteSpan: return parameter.argument(passing: "\(parameter.name)Prefix.span")
        case .outputSpan: return parameter.argument(passing: "&output")
        }
    }
    let keyword = pointer == nil ? "" : "unsafe "
    let calls = ["port", "highway"].map {
        "\(keyword)\(codegenFunctionName($0, referenceName))(\(arguments.joined(separator: ", ")))"
    }

    var statements = spans.map {
        "let \($0.name)Prefix = ContiguousArray(\($0.name).prefix(\($0.name)Count))"
    }
    if let pointer {
        statements.append(
            referenceLoadStatements(
                of: pointer.name,
                aligned: false,
                guardedLanes: guarded ? guardedLanes(of: pointer.name, extent: .first) : nil,
                port: calls[0],
                reference: calls[1],
                description: description
            )
        )
    } else if kernel.parameters.contains(where: { $0.kind == .outputSpan }) {
        let capacity = "\(spans[0].name)Prefix.count"
        statements += [("port", calls[0]), ("reference", calls[1])].map { side, call in
            """
            let (\(side)Result, \(side)Lanes) = withOutputSpan(capacity: \(capacity)) { output in
            \(call)
            }
            """
        }
        statements.append("mismatches.check(portResult, referenceResult, \(description))")
        statements.append("mismatches.check(portLanes, referenceLanes, \(description))")
    } else {
        statements.append("mismatches.check(\(calls[0]), \(calls[1]), \(description))")
    }

    return referenceTestFunction(
        test,
        label: guarded ? "\(function) before a guard page" : function,
        for: element,
        inputs: inputs,
        statements: statements.joined(separator: "\n")
    )
}

func generateCodegenTests(_ element: Element) -> String {
    var tests: [String] = []
    for op in ops where op.applies.matches(element) {
        let parameters = codegenParameters(of: op, for: element)
        for constant in codegenVariants(of: parameters, for: element) {
            tests.append(codegenTest(of: op, for: element, constant: constant))
            if op.span != nil {
                tests.append(codegenTest(of: op, for: element, constant: constant, guarded: true))
            }
        }
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            let parameters = codegenParameters(of: op, from: narrow)
            for constant in codegenVariants(of: parameters, for: element) {
                for guarded in [false, true] {
                    tests.append(
                        codegenWideningTest(
                            op,
                            from: narrow,
                            to: element,
                            constant: constant,
                            guarded: guarded
                        )
                    )
                }
            }
        }
    }
    tests.append(codegenRepeatingBlockTest(for: element))
    for kernel in codegenKernels where kernel.applies.matches(element) {
        tests.append(codegenKernelTest(kernel, for: element))
        if kernel.parameters.contains(where: { $0.kind == .pointer }) {
            tests.append(codegenKernelTest(kernel, for: element, guarded: true))
        }
    }

    return """
        \(generationNotice)

        import CHighwayReference
        import HighwayReferenceCodegen
        import Testing
        import Vectorization

        @Suite("\(element.namespace) codegen against Highway")
        struct \(element.namespace)CodegenTests {
            typealias H = \(element.namespace)

        \(tests.joined(separator: "\n\n"))
        }

        """
}

struct ConstantValue {
    let name: String
    let literal: String
}

let constantMarkers = [
    "__builtin_constant_p(",
    "cvectorization_ops_sve_splat_",
    "cvectorization_ops_sve_constant_",
]

func headerFunctions(of header: String) -> [String: String] {
    var functions: [String: String] = [:]
    var current: String?
    for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
        if current == nil {
            guard
                line.hasPrefix("CVECTORIZATION_OPS_INLINE")
                    || line.hasPrefix("CVECTORIZATION_OPS_FUNCTION"),
                let open = line.firstIndex(of: "("),
                let name = line[..<open].split(separator: " ").last
            else { continue }
            current = String(name)
        }
        if let name = current {
            functions[name, default: ""] += "\(line)\n"
            if line == "}" {
                current = nil
            }
        }
    }
    return functions
}

func parenthesizedArgument(in text: Substring) -> (argument: Substring, rest: Substring)? {
    var depth = 1
    for index in text.indices {
        switch text[index] {
        case "(":
            depth += 1
        case ")":
            depth -= 1
            if depth == 0 {
                return (text[..<index], text[text.index(after: index)...])
            }
        default:
            break
        }
    }
    return nil
}

func constantIdentifiers(in source: String) -> Set<String> {
    var identifiers: Set<String> = []
    for marker in constantMarkers {
        var remainder = source[...]
        while let range = remainder.range(of: marker) {
            remainder = remainder[range.upperBound...]
            if !marker.hasSuffix("(") {
                guard let open = remainder.firstIndex(of: "(") else { break }
                remainder = remainder[remainder.index(after: open)...]
            }
            guard let (argument, rest) = parenthesizedArgument(in: remainder) else { break }
            identifiers.formUnion(
                argument.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
            )
            remainder = rest
        }
    }
    return identifiers
}

func constantSource(ofFunctionNamed name: String) -> String {
    let prefix = "cvectorization_ops_"
    guard name.hasPrefix(prefix) else { fatalError("\(name) is not a function of the header") }
    return ["", "neon_", "x86_"].compactMap { helper in
        generatedFunctions["\(prefix)\(helper)\(name.dropFirst(prefix.count))"]
    }.joined()
}

func constantParameters(of op: Op, for element: Element) -> [Int] {
    let identifiers = constantIdentifiers(
        in: constantSource(ofFunctionNamed: cFunctionName(op.identifier, element))
    )
    return zip(bindings(of: op, for: element), op.parameters).enumerated().compactMap {
        index,
        pair in
        let isFloatOperand = element.category == .float && isConstantVector(pair.1)
        return isFloatOperand || (pair.1 != .tag && identifiers.contains(pair.0.swiftName))
            ? index : nil
    }
}

func constantCounts(spanned: Bool, for element: Element) -> [Int] {
    let laneCounts = [16, 32, 64].map { element.at(width: $0).laneCount }
    let beyond32Bits = laneCounts.flatMap { [1 << 32, (1 << 32) + 1, (1 << 32) + $0] }
    let through = Array(0...(laneCounts.max()! + 1))
    let limit = element.bits >= Int.bitWidth ? Int.max : (1 << (element.bits - 1)) - 1
    let counts =
        spanned
        ? through + laneCounts.map { 2 * $0 } + [1000] + beyond32Bits
        : through + [limit] + beyond32Bits.filter { $0 <= limit }
    return counts.reduce(into: []) { unique, count in
        if !unique.contains(count) {
            unique.append(count)
        }
    }
}

func integerConstantName(_ value: Int) -> String {
    value < 0 ? "Minus\(-value)" : "\(value)"
}

func integerConstants(_ values: [Int]) -> [ConstantValue] {
    values.map { ConstantValue(name: integerConstantName($0), literal: "\($0)") }
}

func integerSplats(for element: Element) -> [ConstantValue] {
    let signed = element.category == .signedInteger
    let upper = element.bits == 64 ? Int.max : (1 << (element.bits - (signed ? 1 : 0))) - 1
    let lower = signed ? (element.bits == 64 ? Int.min : -(1 << (element.bits - 1))) : 0
    let candidates =
        [0, 1, 15, 16, 26, 127, 128, 255, 256, 257, 65280, 65281]
        + (signed ? [-1, -16, -17, -128, -129] : [])
    let fitting = candidates.filter { (lower...upper).contains($0) }
    let extremes = [("Max", "H.Lane.max", upper), ("Min", "H.Lane.min", lower)]
        .filter { _, _, value in signed || value == upper }
        .filter { _, _, value in !fitting.contains(value) }
    return integerConstants(fitting)
        + extremes.map { ConstantValue(name: $0.0, literal: $0.1) }
}

let floatSplats = [
    ConstantValue(name: "Zero", literal: "0.0"),
    ConstantValue(name: "NegativeZero", literal: "-0.0"),
    ConstantValue(name: "One", literal: "1.0"),
    ConstantValue(name: "MinusOne", literal: "-1.0"),
    ConstantValue(name: "Two", literal: "2.0"),
    ConstantValue(name: "Half", literal: "0.5"),
    ConstantValue(name: "Four", literal: "4.0"),
    ConstantValue(name: "Quarter", literal: "0.25"),
    ConstantValue(name: "OnePointFive", literal: "1.5"),
    ConstantValue(name: "MinusTwoPointFive", literal: "-2.5"),
    ConstantValue(name: "Infinity", literal: ".infinity"),
    ConstantValue(name: "MinusInfinity", literal: "-.infinity"),
    ConstantValue(name: "NaN", literal: ".nan"),
    ConstantValue(name: "MinusNaN", literal: "-.nan"),
    ConstantValue(name: "PayloadNaN", literal: "H.Lane(nan: 1, signaling: false)"),
    ConstantValue(name: "SignalingNaN", literal: ".signalingNaN"),
    ConstantValue(name: "MinusSignalingNaN", literal: "-.signalingNaN"),
    ConstantValue(name: "LeastNonzero", literal: ".leastNonzeroMagnitude"),
    ConstantValue(name: "Greatest", literal: ".greatestFiniteMagnitude"),
]

func constantSplats(for element: Element) -> [ConstantValue] {
    element.category == .float ? floatSplats : integerSplats(for: element)
}

func constantHelperName(
    of op: Op,
    parameter binding: Binding,
    guarded: Bool
) -> String {
    let name = "check\(uppercasedFirst(op.identifier))Constant\(uppercasedFirst(binding.swiftName))"
    return guarded ? "\(name)BeforeGuardPage" : name
}

func constantHelperSignature(_ name: String, _ parameter: String, _ type: String) -> String {
    "@inline(__always)\nprivate func \(name)(_ \(parameter): \(type)) {"
}

func isConstantVector(_ parameter: Parameter) -> Bool {
    switch parameter {
    case .vector, .fillVector, .otherwiseVector: return true
    default: return false
    }
}

func constantHelper(
    of op: Op,
    for element: Element,
    parameter index: Int,
    guarded: Bool
) -> String {
    let parameterBindings = bindings(of: op, for: element)
    let binding = parameterBindings[index]
    let isSplat = isConstantVector(op.parameters[index])
    let name = constantHelperName(of: op, parameter: binding, guarded: guarded)
    let value = isSplat ? "value" : binding.swiftName
    let splat = portCall("repeating", [value])
    let inputs = referenceInputs(of: op, for: element, test: name, inContract: true)
        .filter { $0.name != binding.swiftName }
    let calls = referenceCalls(
        of: op,
        for: element,
        pointer: referencePointer(of: op, guarded: guarded),
        constants: isSplat ? [binding.swiftName: (port: splat, reference: splat)] : [:]
    )
    let (declarations, statements) = referenceStatements(
        of: op,
        for: element,
        inputs: inputs,
        guarded: guarded,
        calls: calls
    )
    let highwaySplat = referenceResult(
        referenceCall(referenceFunctionName("repeating", element), [value]),
        returning: .vector,
        for: element
    )
    let splatDeclarations =
        isSplat ? ["mismatches.check(\(splat), \(highwaySplat), \"repeating\")"] : []
    let vectors = zip(parameterBindings, op.parameters)
        .filter { $0.1 == .vector }
        .map { $0.0.swiftName == binding.swiftName && isSplat ? splat : $0.0.swiftName }
    let describedValue = isSplat ? "repeating \\(hex(value))" : "\\(\(value))"
    let suffix = guarded ? " before a guard page" : ""
    return referenceTestFunction(
        name,
        label: "\(op.identifier) with \(binding.swiftName) \(describedValue)\(suffix)",
        for: element,
        inputs: inputs,
        declarations: splatDeclarations + declarations,
        signature: constantHelperSignature(name, value, isSplat ? "H.Lane" : "Int"),
        loopCondition: unorderedNaNsCondition(of: op, for: element, vectors: vectors),
        statements: statements
    )
}

func constantTest(_ name: String, enabledIf condition: String? = nil, calls: [String]) -> String {
    let attribute = condition.map { "@Test(.enabled(if: \($0)))" } ?? "@Test"
    return """
        \(attribute) func \(name)() {
        \(calls.joined(separator: "\n"))
        }
        """
}

func constantTests(of op: Op, for element: Element) -> [String] {
    let indices = constantParameters(of: op, for: element)
    let parameterBindings = bindings(of: op, for: element)
    var members: [String] = []

    for index in indices where !isConstantVector(op.parameters[index]) {
        let binding = parameterBindings[index]
        let values: [ConstantValue]
        switch op.parameters[index] {
        case .count:
            values = integerConstants(constantCounts(spanned: op.span != nil, for: element))
        case .laneAmount:
            values = integerConstants(Array(0..<element.at(width: 64).laneCount))
        case .shiftAmount:
            values = integerConstants(Array(0..<element.bits))
        default:
            fatalError("\(op.identifier) branches on \(binding.swiftName), which nothing covers")
        }
        for guarded in op.span == nil ? [false] : [false, true] {
            let helper = constantHelperName(of: op, parameter: binding, guarded: guarded)
            members.append(constantHelper(of: op, for: element, parameter: index, guarded: guarded))
            for value in values {
                let test = "\(op.identifier)Constant\(uppercasedFirst(binding.swiftName))"
                let guardedTest = "\(test)\(value.name)\(guarded ? "BeforeGuardPage" : "")"
                members.append(
                    constantTest(
                        guardedTest,
                        enabledIf: op.parameters[index] == .laneAmount
                            ? "\(value.literal) < H.laneCount" : nil,
                        calls: ["\(helper)(\(value.literal))"]
                    )
                )
            }
        }
    }

    let splats = indices.filter { isConstantVector(op.parameters[$0]) }
    if !splats.isEmpty {
        let helpers = splats.map {
            constantHelperName(of: op, parameter: parameterBindings[$0], guarded: false)
        }
        members += splats.map {
            constantHelper(of: op, for: element, parameter: $0, guarded: false)
        }
        for value in constantSplats(for: element) {
            members.append(
                constantTest(
                    "\(op.identifier)ConstantSplat\(value.name)",
                    calls: helpers.map { "\($0)(\(value.literal))" }
                )
            )
        }
    }
    return members
}

func wideningConstantTests(
    _ op: WideningOp,
    from narrow: Element,
    to wide: Element
) -> [String] {
    let identifiers = constantIdentifiers(
        in: constantSource(ofFunctionNamed: cWideningFunctionName(op, from: narrow, to: wide))
    )
    guard op.takesCount, identifiers.contains("count") else { return [] }
    var members: [String] = []
    for guarded in [false, true] {
        let name = "\(op.swiftName)From\(narrow.swiftType)\(guarded ? "BeforeGuardPage" : "")"
        let helper = "check\(uppercasedFirst(name))ConstantCount"
        members.append(
            wideningReferenceTest(op, from: narrow, to: wide, guarded: guarded, constantCount: true)
        )
        for value in integerConstants(constantCounts(spanned: true, for: wide)) {
            members.append(
                constantTest(
                    "\(name)ConstantCount\(value.name)",
                    calls: ["\(helper)(\(value.literal))"]
                )
            )
        }
    }
    return members
}

func generateConstantTests(_ element: Element) -> String {
    var members: [String] = []
    for op in ops where op.applies.matches(element) {
        members += constantTests(of: op, for: element)
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            members += wideningConstantTests(op, from: narrow, to: element)
        }
    }

    return """
        \(generationNotice)

        import CHighwayReference
        import Testing
        import Vectorization

        @Suite("\(element.namespace) constants against Highway")
        struct \(element.namespace)ConstantTests {
            typealias H = \(element.namespace)

        \(members.joined(separator: "\n\n"))
        }

        """
}

func generateCodegen(_ element: Element) -> String {
    var functions: [String] = []
    for op in ops where op.applies.matches(element) {
        functions.append(codegenFunctions(of: op, for: element))
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            functions.append(codegenFunctions(op, from: narrow, to: element))
        }
    }
    functions.append(repeatingBlockCodegenFunctions(for: element))
    for kernel in codegenKernels where kernel.applies.matches(element) {
        functions.append(codegenKernelFunctions(kernel, for: element))
    }

    return """
        \(generationNotice)

        import CHighwayReference
        public import Vectorization

        \(referenceSpanNamespace(of: element))

        \(functions.joined(separator: "\n\n"))

        """
}

func generateCodegenTarget() -> String {
    """
    \(generationNotice)

    import CHighwayReference

    @inline(never)
    public func targetOfHighway(_ target: HighwayReference.Target) {}

    """
}

func write(_ contents: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("** Wrote \(path)\n".utf8))
}

let repositoryRoot = FileManager.default.currentDirectoryPath
let headerPath = "\(repositoryRoot)/Sources/CVectorizationOps/include/CVectorizationOps.h"
let referenceHeaderPath =
    "\(repositoryRoot)/HighwayReference/CHighwayReference/include/CHighwayReference.h"
let generatedSwiftRoot = "\(repositoryRoot)/Sources/Vectorization/Generated"
let generatedReferenceTestsRoot =
    "\(repositoryRoot)/HighwayReference/HighwayReferenceTests/Generated"
let generatedCodegenRoot =
    "\(repositoryRoot)/HighwayReference/HighwayReferenceCodegen/Generated"

// The generated Swift is formatted here rather than by hand, so that what this writes and what
// `swift format` wants can never disagree, which would make the two CI checks fight each other.
func format(_ path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "format", "format", "--in-place", "--parallel", "--recursive", path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("** ERROR: failed to format \(path)\n".utf8))
        exit(1)
    }
}

try? FileManager.default.removeItem(atPath: generatedSwiftRoot)
try? FileManager.default.removeItem(atPath: generatedReferenceTestsRoot)
try? FileManager.default.removeItem(atPath: generatedCodegenRoot)
let generatedHeader = generateHeader()
let generatedFunctions = headerFunctions(of: generatedHeader)
try write(generatedHeader, to: headerPath)
try write(generateReferenceHeader(), to: referenceHeaderPath)
try write(
    generateReferenceTargetTests(),
    to: "\(generatedReferenceTestsRoot)/HighwayTargetReferenceTests.swift"
)
try write(generateCodegenTarget(), to: "\(generatedCodegenRoot)/HighwayTargetCodegen.swift")
try write(generateProtocols(), to: "\(generatedSwiftRoot)/SIMDElement.swift")
for element in elements {
    try write(generateElement(element), to: "\(generatedSwiftRoot)/\(element.namespace).swift")
    try write(
        generateReferenceTests(element),
        to: "\(generatedReferenceTestsRoot)/\(element.namespace)ReferenceTests.swift"
    )
    try write(
        generateCodegen(element),
        to: "\(generatedCodegenRoot)/\(element.namespace)Codegen.swift"
    )
    try write(
        generateCodegenTests(element),
        to: "\(generatedReferenceTestsRoot)/\(element.namespace)CodegenTests.swift"
    )
    try write(
        generateConstantTests(element),
        to: "\(generatedReferenceTestsRoot)/\(element.namespace)ConstantTests.swift"
    )
}
try format(generatedSwiftRoot)
try format(generatedReferenceTestsRoot)
try format(generatedCodegenRoot)
FileHandle.standardError.write(
    Data("** ✅ Generated \(elements.count) element types.\n".utf8)
)
