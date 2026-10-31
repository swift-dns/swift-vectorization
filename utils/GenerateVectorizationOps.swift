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

    var tag: String { "Tag\(suffix)" }
    var vector: String { "Vector\(suffix)" }
    var mask: String { "Mask\(suffix)" }
    var namespace: String { "SIMD\(swiftType)" }
    var laneCount: Int { 128 / bits }
    var cSuffix: String { suffix.lowercased() }
    var cVector: String { "cvectorization_ops_vector_\(cSuffix)" }
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
    var swiftVector: String { "SIMD\(laneCount)<\(swiftType)>" }
    var swiftMask: String { "SIMDMask<SIMD\(laneCount)<\(swiftMaskLane)>>" }
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
enum SpanExtent {
    case vectors(Int, aligned: Bool = false)
    case first
}

struct TargetBodies<Input> {
    var neon: ((Input) -> String?)?
    var sse4: ((Input) -> String?)?
    var ssse3: ((Input) -> String?)?
    var sse2: ((Input) -> String?)?
}

struct Op {
    let swiftName: String
    let highwayName: String
    let parameters: [Parameter]
    let returns: ReturnType
    let applies: Applies
    var documentation: String = ""
    let span: SpanExtent?
    let targets: TargetBodies<Element>
    let helpers: TargetBodies<Element>
    let portable: (Element) -> String

    init(
        _ swiftName: String,
        _ highwayName: String,
        _ parameters: [Parameter],
        _ returns: ReturnType,
        _ applies: Applies,
        _ documentation: String = "",
        span: SpanExtent? = nil,
        targets: TargetBodies<Element> = TargetBodies(),
        helpers: TargetBodies<Element> = TargetBodies(),
        portable: @escaping (Element) -> String
    ) {
        self.swiftName = swiftName
        self.highwayName = highwayName
        self.parameters = parameters
        self.returns = returns
        self.applies = applies
        self.documentation = documentation
        self.span = span
        self.targets = targets
        self.helpers = helpers
        self.portable = portable
    }

    var operands: [Parameter] {
        parameters.filter { $0 != .tag }
    }

    /// The positions in `operands` of the parameters in the order Swift declares them.
    var swiftOrder: [Int] {
        let operands = self.operands
        return operands.indices.sorted {
            (operands[$0].overloading?.rank ?? 0, $0) < (operands[$1].overloading?.rank ?? 0, $1)
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

func clampedCount(to lanes: Int) -> String {
    "(count < \(lanes) ? count : \(lanes))"
}

func signedFirstLanes(for element: Element) -> String {
    let lanes = element.laneCount
    let offsets = iota(as: element.cMask, lanes: lanes)
    guard
        let unsigned = elements.first(where: {
            $0.category == .unsignedInteger && $0.bits == element.bits
        })
    else {
        fatalError("There is no unsigned element of \(element.bits) bits")
    }
    let limit = "(\(element.cMask))\(repeatingVector("(\(unsigned.cType))n", of: unsigned))"
    return """
        const \(element.cMaskLane) n = (\(element.cMaskLane))\(clampedCount(to: lanes));
        \(maskResult("\(limit) > \(offsets)", for: element))
        """
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
    return """
        \(mask) take = (\(mask))(a \(symbol) b) | ((\(mask))(b != b) & (\(mask))(a == a));
        \(vectorResult(bitSelect("take", "a", "b", of: element), for: element))
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

func assumedAligned(_ pointer: String) -> String {
    "__builtin_assume_aligned(\(pointer), 16)"
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

func loadInterleaved(channels: Int, for element: Element) -> String {
    let names = (0..<channels).map { "buf\($0)" }
    let declarations = names.map {
        "\(element.cType) \($0)[\(element.laneCount)] __attribute__((aligned(16)));"
    }
    let loads = names.map { "  \($0)[i] = *from++;" }
    let load = cFunctionName("loadAligned", element)
    let stores = names.enumerated().map { channel, name in
        element.bits >= 32
            ? "__builtin_memcpy(v\(channel), \(name), sizeof *v\(channel));"
            : "*v\(channel) = (\(element.cVector))\(load)(\(name));"
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
    let stores = ["a", "b", "c", "d"].prefix(channels).map { name in
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
    let lane: String
    let attribute: String
}

func neonVector(_ suffix: String) -> String {
    "cvectorization_ops_neon_\(suffix)"
}

func x86Vector(_ suffix: String) -> String {
    "cvectorization_ops_x86_\(suffix)"
}

let x86IfThenElseName = "cvectorization_ops_x86_if_then_else"

func x86GreaterThanName(bits: Int) -> String {
    "cvectorization_ops_x86_greater_than_i\(bits)"
}

func x86AsFloatName(bits: Int) -> String {
    "cvectorization_ops_x86_as_f\(bits)"
}

let neonVectors: [RawVector] = [
    RawVector(name: neonVector("i8x8"), lane: "int8_t", attribute: "neon_vector_type(8)"),
    RawVector(name: neonVector("i8"), lane: "int8_t", attribute: "neon_vector_type(16)"),
    RawVector(name: neonVector("f32"), lane: "float", attribute: "neon_vector_type(4)"),
    RawVector(name: neonVector("f64"), lane: "double", attribute: "neon_vector_type(2)"),
]

let x86Vectors: [RawVector] = [
    RawVector(name: x86Vector("i8"), lane: "char", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("i16"), lane: "short", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("i32"), lane: "int", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("i64"), lane: "long long", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("f32"), lane: "float", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("f64"), lane: "double", attribute: "vector_size(16)"),
]

func x86RawType(of element: Element) -> String {
    x86Vector(element.hasOpaqueVector ? "i64" : element.cSuffix)
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

func neonExtremum(_ name: String, for element: Element) -> String {
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
        neonBuiltin(instruction, ["a", "b"], code: code, for: element),
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
        x86Builtin("pmuludq128", [first, second], as: "i32", returning: element.cUnsignedVector)
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

enum X86Level: Comparable {
    case sse2
    case ssse3
    case sse4
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
    _ arguments: [String],
    as suffix: String,
    returning type: String
) -> String {
    let operands = arguments.map { "(\(x86Vector(suffix)))\($0)" }
    return "(\(type))__builtin_ia32_\(name)(\(operands.joined(separator: ", ")))"
}

func x86ShiftCount(_ amount: String) -> String {
    compoundLiteral(x86Vector("i32"), [amount, "0", "0", "0"])
}

func x86ShiftName(_ instruction: String, laneBits: Int) -> String {
    guard let suffix = [16: "w", 32: "d", 64: "q"][laneBits] else {
        fatalError("There is no x86 shift of \(laneBits)-bit lanes")
    }
    return "\(instruction)\(suffix)"
}

func x86Shift(_ instruction: String, laneBits: Int, returning type: String) -> String {
    let name = "\(x86ShiftName(instruction, laneBits: laneBits))128"
    return x86Builtin(name, ["a", x86ShiftCount("bits")], as: "i\(laneBits)", returning: type)
}

func x86ShiftSame(
    _ instruction: String,
    _ operand: String,
    by amount: String,
    into result: String,
    laneBits: Int,
    returning type: String
) -> String {
    let name = x86ShiftName(instruction, laneBits: laneBits)
    let immediate = x86ImmediateShift(
        instruction,
        operand,
        by: amount,
        laneBits: laneBits,
        returning: type
    )
    let register = x86Builtin(
        "\(name)128",
        [operand, x86ShiftCount(amount)],
        as: "i\(laneBits)",
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
        let shifted = x86Shift("psll", laneBits: element.bits, returning: element.cVector)
        return vectorResult(shifted, for: element)
    }
    let unsigned = element.cUnsignedVector
    let shifted = x86Shift("psll", laneBits: 16, returning: unsigned)
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
        let shifted = x86Shift("psrl", laneBits: 16, returning: unsigned)
        let mask = splat("mask", as: unsigned, lanes: element.laneCount)
        return """
            const \(unsigned) shifted = \(shifted);
            const uint8_t mask = (uint8_t)(0xFF >> (bits & 31));
            \(vectorResult("shifted & \(mask)", for: element))
            """
    case (.signedInteger, 8):
        let shifted = x86Shift("psrl", laneBits: 16, returning: unsigned)
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
    case (.signedInteger, 64):
        let vector = element.cVector
        let right = x86ShiftSame(
            "psrl",
            "a",
            by: "bits",
            into: "right",
            laneBits: 64,
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
        let shifted = x86Shift(instruction, laneBits: element.bits, returning: element.cVector)
        return vectorResult(shifted, for: element)
    }
}

func x86Extremum(
    _ name: String,
    _ first: String,
    _ second: String,
    for element: Element
) -> String {
    "__builtin_ia32_\(name)\(element.bits == 32 ? "ps" : "pd")(\(first), \(second))"
}

func x86IsNaN(for element: Element) -> String {
    "__builtin_ia32_cmp\(element.bits == 32 ? "ps" : "pd")(a, a, 3)"
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
    if isSignedInteger64(element) {
        let chosen = isMinimum ? (first: "a", second: "b") : (first: "b", second: "a")
        return x86Int64Extremum(chosen, native: level >= .sse4, for: element)
    }
    let hasInstruction = element.bits == (element.category == .signedInteger ? 16 : 8)
    guard !hasInstruction else { return nil }
    guard level < .sse4 else { return elementwiseExtremum(name, comparing: symbol, for: element) }
    if let compared = x86ComparedExtremum(reduction, for: element) { return compared }
    return x86CombinedExtremum(reduction, for: element)
}

func x86RoundedAverage(for element: Element) -> String {
    let name = element.bits == 8 ? "pavgb128" : "pavgw128"
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
    reduction != .sum && level >= .sse4 && element.category == .unsignedInteger
        && element.bits == 16
}

func x86Reduction(_ reduction: Reduction, level: X86Level, for element: Element) -> String {
    if x86UsesMinimumPosition(reduction, level: level, for: element) {
        return x86MinimumPosition(reduction, for: element)
    }
    let names: [(reversed: String, reduced: String)]
    switch element.laneCount {
    case 2: names = [("reversed", "combined")]
    case 4: names = [("reversed", "pairs"), ("swapped", "combined")]
    default: names = [("reversed", "quads"), ("flipped", "pairs"), ("swapped", "combined")]
    }
    let vector = element.cVector
    let raw = element.cRawVector
    let combining = x86CombiningFunctionName(reduction, element)
    var statements: [String] = []
    var reduced = "a"
    for (step, name) in names.enumerated() {
        let group = element.laneCount >> step
        statements.append(
            x86Reverse(reduced, into: name.reversed, lanes: group, level: level, for: element)
        )
        let combined = "\(combining)((\(raw))\(reduced), (\(raw))\(name.reversed))"
        statements.append("const \(vector) \(name.reduced) = (\(vector))\(combined);")
        reduced = name.reduced
    }
    statements.append("return \(reduced)[0];")
    return statements.joined(separator: "\n")
}

func portableReverse(for element: Element) -> String {
    let indices = (0..<element.laneCount).reversed().map(String.init)
    return vectorResult(
        "__builtin_shufflevector(a, a, \(indices.joined(separator: ", ")))",
        for: element
    )
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
    x86Builtin("pshufb128", [bytes, indices], as: "i8", returning: element.cVector)
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

func slideConstants(
    _ direction: SlideDirection,
    byteShifted: Bool = false,
    for element: Element
) -> String {
    let cases = (1..<element.laneCount).map { amount in
        let shuffle =
            byteShifted
            ? x86SlideBytes(direction, by: amount, for: element)
            : slideShuffle(direction, by: amount, for: element)
        return "case \(amount): \(vectorResult(shuffle, for: element))"
    }
    let unshifted = "case 0: \(vectorResult("a", for: element))"
    return """
        if (__builtin_constant_p(lanes)) {
          switch (lanes) {
        \(indented(indented(([unshifted] + cases).joined(separator: "\n"))))
          }
        }
        """
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
        let first = splat("first", as: bytes, lanes: 16)
        return """
            const uint8_t first = (uint8_t)(0 - lanes * sizeof(\(element.cType)));
            const \(bytes) indices = \(first) + \(iota(as: bytes, lanes: 16));
            """
    case .down:
        let bytes = x86Vector("i8")
        let first = splat("first", as: bytes, lanes: 16)
        let limit = splat("15", as: bytes, lanes: 16)
        return """
            const int8_t first = (int8_t)(lanes * sizeof(\(element.cType)));
            const \(bytes) offsets = \(first) + \(iota(as: bytes, lanes: 16));
            const \(bytes) indices = offsets | (offsets > \(limit));
            """
    }
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
        returning: vector
    )
    let otherShifted = x86ShiftSame(
        otherShift,
        other,
        by: "64 - shift",
        into: shiftedOther,
        laneBits: 64,
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

func portableSlideCopy(
    _ direction: SlideDirection,
    by lanes: String,
    for element: Element
) -> String {
    let lane = element.cType
    let (destination, source) =
        switch direction {
        case .up: ("(\(lane)*)&result + \(lanes)", "&a")
        case .down: ("&result", "(const \(lane)*)&a + \(lanes)")
        }
    let kept = "(\(element.laneCount) - \(lanes)) * sizeof(\(lane))"
    return "__builtin_memcpy(\(destination), \(source), \(kept));"
}

func portableSlide(_ direction: SlideDirection, for element: Element) -> String {
    let lanes = element.laneCount
    return """
        \(element.cVector) result = {0};
        const size_t clamped = lanes < \(lanes) ? lanes : \(lanes);
        \(portableSlideCopy(direction, by: "clamped", for: element))
        \(vectorResult("result", for: element))
        """
}

func portableSlide1(_ direction: SlideDirection, for element: Element) -> String {
    """
    \(element.cVector) result = {0};
    \(portableSlideCopy(direction, by: "1", for: element))
    \(vectorResult("result", for: element))
    """
}

func shuffledSlide1(_ direction: SlideDirection, for element: Element) -> String {
    vectorResult(slideShuffle(direction, by: 1, for: element), for: element)
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

func slide1FillingTargets(_ direction: SlideDirection) -> TargetBodies<Element> {
    TargetBodies(
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

func maskedBitwiseOtherwise(_ symbol: String, for element: Element) -> String {
    let selecting = cFunctionName("selecting", element)
    let raw = element.cRawVector
    let operands = ["(\(element.cRawMask))mask", "(\(raw))(a \(symbol) b)", "(\(raw))otherwise"]
    return "return \(selecting)(\(operands.joined(separator: ", ")));"
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

func x86SignedGreater(_ first: String, _ second: String, for element: Element) -> String {
    guard element.bits == 64 else {
        let mask = element.cMask
        return "const \(mask) mask = (\(mask))(\(first) > \(second));"
    }
    return x86Int64Greater(first, second, for: element)
}

func x86UnsignedGreater(_ first: String, _ second: String, for element: Element) -> String {
    let signed = x86Vector("i\(element.bits)")
    let signBit = String(UInt64(1) << UInt64(element.bits - 1), radix: 16)
    let i64 = x86Vector("i64")
    return """
        const \(element.cVector) flip = \(repeatingVector("0x\(signBit)", of: element));
        const \(signed) signedFirst = (\(signed))((\(i64))\(first) ^ (\(i64))flip);
        const \(signed) signedSecond = (\(signed))((\(i64))\(second) ^ (\(i64))flip);
        \(x86SignedGreater("signedFirst", "signedSecond", for: element))
        """
}

func x86Int64Comparison(_ first: String, _ second: String, for element: Element) -> String {
    "\(x86Int64Greater(first, second, for: element))\n\(maskResult("mask", for: element))"
}

func x86UnsignedComparison(_ first: String, _ second: String, for element: Element) -> String {
    "\(x86UnsignedGreater(first, second, for: element))\n\(maskResult("mask", for: element))"
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
        ? ("blendv\(element.bits == 32 ? "ps" : "pd")", element.cSuffix)
        : ("pblendvb128", "i8")
    return x86Builtin(name, [no, yes, mask], as: suffix, returning: element.cVector)
}

func x86BitSelect(_ mask: String, _ yes: String, _ no: String, for element: Element) -> String {
    guard element.category != .float else { return bitSelect(mask, yes, no, of: element) }
    let i64 = x86Vector("i64")
    let chosen = "(\(i64))\(mask) & (\(i64))\(yes)"
    let rest = "~(\(i64))\(mask) & (\(i64))\(no)"
    return "(\(element.cVector))((\(chosen)) | (\(rest)))"
}

func x86Slide1Up(for element: Element) -> String {
    vectorResult(x86SlideBytes(.up, by: 1, for: element), for: element)
}

func x86MaskBits(for element: Element) -> String {
    switch element.bits {
    case 8:
        return x86Builtin("pmovmskb128", ["mask"], as: "i8", returning: "int")
    case 16:
        let zero = compoundLiteral(x86Vector("i16"), ["0"])
        let packed = x86Builtin(
            "packsswb128",
            ["mask", zero],
            as: "i16",
            returning: x86Vector("i8")
        )
        return x86Builtin("pmovmskb128", [packed], as: "i8", returning: "int")
    case 32:
        return x86Builtin("movmskps", ["mask"], as: "f32", returning: "int")
    default:
        return x86Builtin("movmskpd", ["mask"], as: "f64", returning: "int")
    }
}

func x86AllTrue(for element: Element) -> String {
    let allBits = "0x\(String((1 << element.laneCount) - 1, radix: 16))"
    return "return \(x86MaskBits(for: element)) == \(allBits);"
}

func x86FirstTrueIndex(for element: Element) -> String {
    """
    const unsigned bits = (unsigned)\(x86MaskBits(for: element));
    return bits ? (intptr_t)__builtin_ctz(bits | 0x80000000u) : -1;
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

func x86PromotionHelper(from narrow: Element, to wide: Element) -> String {
    let vector = narrow.cVector
    let lowest = laneIndices(0..<wide.laneCount)
    let converted = vectorResult(
        "__builtin_convertvector(__builtin_shufflevector(a, a, \(lowest)), \(wide.cVector))",
        for: wide
    )
    let levels = TargetBodies<Element>(
        sse4: { _ in converted },
        ssse3: { wide in x86Promotion(of: "a", from: narrow, to: wide, level: .ssse3) },
        sse2: { wide in x86Promotion(of: "a", from: narrow, to: wide, level: .sse2) }
    )
    let promotion =
        narrow.category == .float ? converted : cBody(levels, for: wide, portable: nil)
    return cFunction(
        returns: wide.cRawVector,
        name: x86PromotionName(from: narrow, to: wide),
        parameters: ["\(x86RawType(of: narrow)) v"],
        body: "const \(vector) a = (\(vector))v;\n\(promotion)"
    )
    .trimmingCharacters(in: .newlines)
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
            isFloating: isFloating
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
            isFloating: isFloating
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
        let indices = laneIndices(step.indices)
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
    let shuffles = steps.flatMap { step in
        let store = "*v\(step.name.dropFirst()) = (\(element.cVector))\(step.name);"
        return x86Shuffles([step], for: element) + (step.name.hasPrefix("r") ? [store] : [])
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

func x86ImmediateShift(
    _ instruction: String,
    _ operand: String,
    by amount: String,
    laneBits: Int,
    returning type: String
) -> String {
    let name = x86ShiftName(instruction, laneBits: laneBits)
    let vector = x86Vector("i\(laneBits)")
    return "(\(type))__builtin_ia32_\(name)i128((\(vector))\(operand), \(amount))"
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
                *v0 = \(packed);
                """
        } else if level >= .ssse3 {
            let table =
                [0x00, 0x01, 0x04, 0x05, 0x08, 0x09, 0x0C, 0x0D] + Array(repeating: 0, count: 8)
            let lookup: (String) -> String = {
                x86Builtin("pshufb128", [$0, "shuffle"], as: "i8", returning: i8)
            }
            evens = """
                const \(i8) shuffle = \(compoundLiteral(i8, table.map(String.init)));
                const \(i8) evenLow = \(lookup("first"));
                const \(i8) evenHigh = \(lookup("second"));
                *v0 = (\(vector))__builtin_shufflevector(
                  (\(i64))evenLow, (\(i64))evenHigh, 0, 2);
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
                *v0 = \(packed);
                """
        }
        let packed = x86Builtin("packssdw128", ["oddLow", "oddHigh"], as: "i32", returning: vector)
        return """
            \(loads)
            \(evens)
            const \(i32) oddHigh = \(shiftedRight("second"));
            const \(i32) oddLow = \(shiftedRight("first"));
            *v1 = \(packed);
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
        *v0 = \(evens);
        const \(i16) oddHigh = \(shiftedRight("second"));
        const \(i16) oddLow = \(shiftedRight("first"));
        *v1 = \(odds);
        """
}

func x86LoadInterleaved3Lookups(level: X86Level, for element: Element) -> String {
    let type = x86Vector("i8")
    let blocks = ["vA", "vB", "vC"]
    let laneBytes = element.bits / 8
    let blockLanes = 16 / laneBytes
    let loads = blocks.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(blockLanes * index), sizeof \(name));"
    }
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
        return "*v\(channel) = (\(element.cVector))(\(combined));"
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

func unpackIndices(lanes: Int, upper: Bool) -> [Int] {
    let start = upper ? lanes / 2 : 0
    return (start..<start + lanes / 2).flatMap { [$0, $0 + lanes] }
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
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    let f32 = x86Vector("f32")
    let f64 = x86Vector("f64")
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
    return words + [long, single, pair, lone]
}

func x86InterleaveLowerHelpers() -> [String] {
    let i64 = x86Vector("i64")
    return [16, 32, 64].map { bits in
        let unit = x86Vector("i\(bits)")
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
    let inserted = """
        \(vector) a = (\(vector))rawA;
        a[\(lane)] = t;
        \(vectorResult("a", for: element))
        """
    let selected = x86BitSelect("selected", repeatingVector("t", of: element), "a", for: element)
    let blended = """
        const \(vector) a = (\(vector))rawA;
        const \(element.cMask) selected = \(laneMask(lane, for: element));
        \(vectorResult(selected, for: element))
        """
    let levels = TargetBodies<Element>(sse4: { _ in inserted }, sse2: { _ in blended })
    return cFunction(
        returns: element.cRawVector,
        name: x86InsertLaneName(lane, for: element),
        parameters: ["\(element.cRawVector) rawA", "\(element.cType) t"],
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
    return Set(wides.map(\.laneCount)).sorted()
}

func x86LoadFirstHelpers(for element: Element) -> String? {
    let partialLanes = x86PartialLoadFirstLanes(of: element)
    var helpers: [String] = []
    if ([element.laneCount] + partialLanes).contains(4) {
        helpers.append(x86InsertLane(2, for: element))
    }
    helpers += partialLanes.map { lanes in
        cFunction(
            returns: x86RawType(of: element),
            name: x86LoadFirstName(lanes: lanes, for: element),
            parameters: ["const \(element.cType)* from", "size_t count"],
            body: x86LoadFirst(lanes: lanes, for: element)
        )
    }
    return helpers.isEmpty ? nil : helpers.joined().trimmingCharacters(in: .newlines)
}

/// Highway's `LoadN`, with a call wherever Highway calls an op, so that LLVM simplifies each part
/// before inlining it the way it does Highway's. `StoreN`s follow the same structure.
func x86LoadFirst(lanes: Int, for element: Element) -> String {
    let size = element.bits / 8
    let raw = x86RawType(of: element)
    func load(_ lanes: Int, at pointer: String) -> String {
        let function =
            lanes * size == 16
            ? cFunctionName("load", element)
            : x86PartialName("load", bytes: lanes * size, for: element)
        return "\(function)(\(pointer))"
    }
    func interleaving(_ low: String, _ high: String, halfLanes: Int) -> String {
        "\(x86InterleaveLowerName(bits: 8 * halfLanes * size))(\(low), \(high))"
    }
    let head = """
        if (count >= \(lanes)) {
          return \(load(lanes, at: "from"));
        }
        if (count == 0) {
          return \(cFunctionName("zero", element))();
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
        \(raw) trailing = \(cFunctionName("zero", element))();
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
    let i64 = x86Vector("i64")
    let f32 = x86Vector("f32")
    let f64 = x86Vector("f64")
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
    return words + [long, single, pair, lone]
}

func x86UpperHalfHelpers() -> [String] {
    let i8 = x86Vector("i8")
    let i64 = x86Vector("i64")
    let f32 = x86Vector("f32")
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
        let function =
            lanes * size == 16
            ? cFunctionName("store", element)
            : x86PartialName("store", bytes: lanes * size, for: element)
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
    let raw = x86RawType(of: element)
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

func x86StoreFirst(for element: Element) -> String {
    let raw = x86RawType(of: element)
    return """
        const \(raw) v = (\(raw))a;
        \(x86StoreFirstTree(lanes: element.laneCount, of: "v", for: element))
        """
}

func shuffleLoadInterleaved(channels: Int, for element: Element) -> String {
    let lanes = element.laneCount
    let splits = (0..<channels).map { channel in
        let indices = laneIndices((0..<lanes).map { channels * $0 + channel })
        return "*v\(channel) = (\(element.cVector))__builtin_shufflevector(all, all, \(indices));"
    }
    return """
        typedef \(element.cUnsignedLane) wide_vector __attribute__((vector_size(\(16 * channels))));
        wide_vector all;
        __builtin_memcpy(&all, from, \(16 * channels));
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
    let wide = "typedef \(type) wide_vector __attribute__((vector_size(\(16 * channels))));"
    let pair = "typedef \(type) pair_vector __attribute__((vector_size(32)));"
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
    statements.append("__builtin_memcpy(to, &all, \(16 * channels));")
    return statements.joined(separator: "\n")
}

let ops: [Op] = [
    Op("zero", "Zero", [.tag], .vector, .all) { element in
        vectorResult(compoundLiteral(element.cVector, ["0"]), for: element)
    },
    Op("repeating", "Set", [.tag, .lane], .vector, .all) { element in
        vectorResult(splat("value", as: element.cVector, lanes: element.laneCount), for: element)
    },
    Op("iota", "Iota", [.tag, .lane], .vector, .all) { element in
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
            sse2: { element in loadedVector(from: assumedAligned("from"), for: element) }
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
        targets: TargetBodies(
            neon: { element in neonLoadFirst(for: element) },
            sse2: { element in x86LoadFirst(lanes: element.laneCount, for: element) }
        ),
        helpers: TargetBodies(sse2: { element in x86LoadFirstHelpers(for: element) })
    ) { element in
        let size = "\(clampedCount(to: element.laneCount)) * sizeof(\(element.cType))"
        return """
            \(zeroedVector(of: element.cVector))
            __builtin_memcpy(&v, from, \(size));
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
        targets: TargetBodies(sse2: { _ in storedVector(to: assumedAligned("to")) })
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
        targets: TargetBodies(
            neon: { element in neonStoreFirst(for: element) },
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

    Op("adding", "Add", [.vector, .vector], .vector, .all) { element in
        binaryArithmetic("+", for: element)
    },
    Op("subtracting", "Sub", [.vector, .vector], .vector, .all) { element in
        binaryArithmetic("-", for: element)
    },
    Op(
        "multiplying",
        "Mul",
        [.vector, .vector],
        .vector,
        .all(bits: [16, 32, 64]),
        targets: TargetBodies(
            neon: { element in isInteger64(element) ? neonMultiplying64(for: element) : nil },
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
            sse4: { element in x86MinMax(.minimum, level: .sse4, for: element) },
            sse2: { element in x86MinMax(.minimum, level: .sse2, for: element) }
        )
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
            sse4: { element in x86MinMax(.maximum, level: .sse4, for: element) },
            sse2: { element in x86MinMax(.maximum, level: .sse2, for: element) }
        )
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
        targets: TargetBodies(
            neon: { element in vectorResult("__builtin_elementwise_fma(a, b, c)", for: element) }
        )
    ) { element in
        withoutContraction(vectorResult("a * b + c", for: element))
    },
    Op(
        "saturatingAdding",
        "SaturatedAdd",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16])
    ) { element in
        vectorResult("__builtin_elementwise_add_sat(a, b)", for: element)
    },
    Op(
        "saturatingSubtracting",
        "SaturatedSub",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16]),
        targets: TargetBodies(neon: { element in neonSaturatingSubtraction(for: element) })
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
            sse2: { element in x86RoundedAverage(for: element) }
        )
    ) { element in
        vectorResult("(a | b) - ((a ^ b) >> 1)", for: element)
    },

    Op("bitwiseAnd", "And", [.vector, .vector], .vector, .integer) { element in
        vectorResult("a & b", for: element)
    },
    Op("bitwiseOr", "Or", [.vector, .vector], .vector, .integer) { element in
        vectorResult("a | b", for: element)
    },
    Op("bitwiseXor", "Xor", [.vector, .vector], .vector, .integer) { element in
        vectorResult("a ^ b", for: element)
    },
    Op("bitwiseNot", "Not", [.vector], .vector, .integer) { element in
        vectorResult("~a", for: element)
    },
    Op("bitwiseAndNot", "AndNot", [.vector, .vector], .vector, .integer) { element in
        vectorResult("~a & b", for: element)
    },
    Op("bitwiseAndXor", "AndXor", [.vector, .vector, .vector], .vector, .integer) { element in
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
            sse4: { element in
                vectorResult(x86Selecting("mask", "a", "b", for: element), for: element)
            }
        )
    ) { element in
        vectorResult(bitSelect("mask", "a", "b", of: element), for: element)
    },
    Op("selectingOrZero", "IfThenElseZero", [.mask, .vector], .vector, .all) { element in
        let mask = "(\(element.cUnsignedVector))mask"
        let selected = fromUnsignedBits("\(mask) & \(unsignedBits("a", of: element))", of: element)
        return vectorResult(selected, for: element)
    },
    Op("zeroingSelected", "IfThenZeroElse", [.mask, .vector], .vector, .all) { element in
        let mask = "(\(element.cUnsignedVector))mask"
        let kept = fromUnsignedBits("~\(mask) & \(unsignedBits("a", of: element))", of: element)
        return vectorResult(kept, for: element)
    },
    Op("bitwiseAnd", "MaskedAnd", [.whereMask, .vector, .vector], .vector, .integer) { element in
        maskedBitwise("&", for: element)
    },
    Op("bitwiseOr", "MaskedOr", [.whereMask, .vector, .vector], .vector, .integer) { element in
        maskedBitwise("|", for: element)
    },
    Op("bitwiseXor", "MaskedXor", [.whereMask, .vector, .vector], .vector, .integer) { element in
        maskedBitwise("^", for: element)
    },
    Op(
        "bitwiseAnd",
        "MaskedAndOr",
        [.otherwiseVector, .whereMask, .vector, .vector],
        .vector,
        .integer
    ) { element in
        maskedBitwiseOtherwise("&", for: element)
    },
    Op(
        "bitwiseOr",
        "MaskedOrOr",
        [.otherwiseVector, .whereMask, .vector, .vector],
        .vector,
        .integer
    ) { element in
        maskedBitwiseOtherwise("|", for: element)
    },
    Op(
        "bitwiseXor",
        "MaskedXorOr",
        [.otherwiseVector, .whereMask, .vector, .vector],
        .vector,
        .integer
    ) { element in
        maskedBitwiseOtherwise("^", for: element)
    },
    Op(
        "multiplyAddingLow52Bits",
        "MulAdd52Lo",
        [.vector, .vector, .vector],
        .vector,
        .unsigned(bits: [64])
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
        targets: TargetBodies(
            neon: { element in signedFirstLanes(for: element) },
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
            sse2: { element in
                "return (size_t)__builtin_popcountll((uint64_t)(unsigned)\(x86MaskBits(for: element)));"
            }
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
            sse2: { element in x86FirstTrueIndex(for: element) }
        )
    ) { element in
        """
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          if (mask[i]) {
            return (intptr_t)i;
          }
        }
        return -1;
        """
    },

    Op(
        "sum",
        "ReduceSum",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        targets: TargetBodies(
            neon: { element in neonReduction("vaddvq", for: element) ?? builtinReduction("add") },
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
        targets: TargetBodies(
            neon: { element in
                neonReduction("vminvq", for: element)
                    ?? neonPairExtremum(comparing: "<", for: element) ?? builtinReduction("min")
            },
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
        targets: TargetBodies(
            neon: { element in
                neonReduction("vmaxvq", for: element)
                    ?? neonPairExtremum(comparing: ">", for: element) ?? builtinReduction("max")
            },
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
        targets: TargetBodies(
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
        targets: TargetBodies(
            neon: { element in shuffledSlide1(.up, for: element) },
            sse2: { element in
                isFloat32(element) ? x86Slide1Up(for: element) : shuffledSlide1(.up, for: element)
            }
        )
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
        targets: TargetBodies(
            neon: { element in shuffledSlide1(.down, for: element) },
            sse2: { element in shuffledSlide1(.down, for: element) }
        )
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
        targets: TargetBodies(
            neon: { element in
                vectorResult(neonTableLookup("a", "b", for: element), for: element)
            },
            ssse3: { element in
                vectorResult(x86TableLookup("a", "b", for: element), for: element)
            },
            sse2: { element in
                """
                \(x86EmulatedTableLookupBytes("a", "b", into: "looked"))
                \(vectorResult("(\(element.cVector))looked", for: element))
                """
            }
        )
    ) { element in
        """
        \(element.cVector) result;
        for (size_t i = 0; i < 16; ++i) {
          const uint8_t index = (uint8_t)b[i];
          result[i] = index < 16 ? a[index] : 0;
        }
        \(vectorResult("result", for: element))
        """
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

// A widening load reads lanes of a narrower element type and promotes each of them to the
// element type of the vector it returns. It is two Highway ops rather than one, and its pointer
// is not a `Lane` pointer, so it does not fit `Op` and is generated on its own below.
struct WideningOp {
    let swiftName: String
    let highwayName: String
    let takesCount: Bool
    var targets = TargetBodies<(narrow: Element, wide: Element)>()

    var span: SpanExtent { takesCount ? .first : .vectors(1) }
}

let wideningOps: [WideningOp] = [
    WideningOp(
        swiftName: "loadWidening",
        highwayName: "LoadU",
        takesCount: false,
        targets: TargetBodies(
            sse2: { narrow, wide in x86Widening(takesCount: false, from: narrow, to: wide) }
        )
    ),
    WideningOp(
        swiftName: "loadFirstWidening",
        highwayName: "LoadN",
        takesCount: true,
        targets: TargetBodies(
            neon: { narrow, wide in neonLoadFirstWidening(from: narrow, to: wide) },
            sse2: { narrow, wide in x86Widening(takesCount: true, from: narrow, to: wide) }
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
    (0..<element.laneCount).map { "v\($0)" }
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
        case .vector, .indices:
            let name = vectorNames.next() ?? "v"
            result.append(
                Binding(
                    declaration: "\(element.vector) \(name)",
                    cDeclaration: "\(element.cRawVector) \(rawName(name))",
                    argument: name,
                    swiftLabel: "_",
                    swiftName: name,
                    swiftType: "\(scope)Vector",
                    isInOut: false
                )
            )
        case .mask, .whereMask:
            result.append(
                Binding(
                    declaration: "\(element.mask) mask",
                    cDeclaration: "\(element.cRawMask) \(rawName("mask"))",
                    argument: "mask",
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
                    declaration: "\(element.vector)& \(name)",
                    cDeclaration: "\(element.cRawVector)* \(rawName(name))",
                    argument: name,
                    swiftLabel: "_",
                    swiftName: name,
                    swiftType: "\(scope)Vector",
                    isInOut: true
                )
            )
        case .fillVector:
            result.append(
                Binding(
                    declaration: "\(element.vector) fill",
                    cDeclaration: "\(element.cRawVector) \(rawName("fill"))",
                    argument: "fill",
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
                    declaration: "\(element.vector) otherwise",
                    cDeclaration: "\(element.cRawVector) \(rawName("otherwise"))",
                    argument: "otherwise",
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

func referenceReturnType(_ returns: ReturnType, _ element: Element) -> String {
    switch returns {
    case .vector: return element.vector
    case .mask: return element.mask
    case .lane: return element.cType
    case .count: return "size_t"
    case .index: return "intptr_t"
    case .boolean: return "bool"
    case .void: return "void"
    }
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
    case .vector: return "HighwayReference.\(element.vector)"
    case .mask: return "HighwayReference.\(element.mask)"
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

func portConversions(of element: Element) -> String {
    let signedTag = "const hn::RebindToSigned<\(element.tag)> di;"
    var output = ""
    output += "HWY_INLINE \(element.vector) \(referenceFunctionName("fromPort", element))"
    output += "(\(element.cVector) v) { return hn::LoadU(\(element.tag)(), "
    output += "reinterpret_cast<const \(element.cType)*>(&v)); }\n"
    output += "HWY_INLINE \(element.cVector) \(referenceFunctionName("toPort", element))"
    output += "(\(element.vector) v) { \(element.cVector) port; "
    output += "hn::StoreU(v, \(element.tag)(), reinterpret_cast<\(element.cType)*>(&port)); "
    output += "return port; }\n"
    output += "HWY_INLINE \(element.mask) \(referenceFunctionName("maskFromPort", element))"
    output += "(\(element.cMask) m) { \(signedTag) return hn::MaskFromVec(hn::BitCast("
    output += "\(element.tag)(), hn::LoadU(di, "
    output += "reinterpret_cast<const \(element.cMaskLane)*>(&m)))); }\n"
    output += "HWY_INLINE \(element.cMask) \(referenceFunctionName("maskToPort", element))"
    output += "(\(element.mask) m) { \(signedTag) \(element.cMask) port; "
    output += "hn::StoreU(hn::BitCast(di, hn::VecFromMask(\(element.tag)(), m)), di, "
    output += "reinterpret_cast<\(element.cMaskLane)*>(&port)); return port; }\n"
    return output
}

func generateReferenceHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_HIGHWAY_REFERENCE_H
        #define SWIFT_HIGHWAY_REFERENCE_H

        #include <stddef.h>
        #include <stdint.h>
        #include "CVectorizationOps.h"

        // HWY_DISABLED_TARGETS is set by the build, see HighwayReference/Package.swift.
        #include "hwy/highway.h"

        #if CVECTORIZATION_OPS_NEON
        #define CHIGHWAY_REFERENCE_TARGETS HWY_ALL_NEON
        #elif CVECTORIZATION_OPS_X86 == 3
        #define CHIGHWAY_REFERENCE_TARGETS HWY_SSE4
        #elif CVECTORIZATION_OPS_X86 == 2
        #define CHIGHWAY_REFERENCE_TARGETS HWY_SSSE3
        #elif CVECTORIZATION_OPS_X86 == 1
        #define CHIGHWAY_REFERENCE_TARGETS HWY_SSE2
        #else
        #define CHIGHWAY_REFERENCE_TARGETS HWY_EMU128
        #endif
        #if !(HWY_TARGET & CHIGHWAY_REFERENCE_TARGETS)
        #error "highway's static target is not the port's"
        #endif

        namespace HighwayReference {
        namespace hn = hwy::HWY_NAMESPACE;

        /// Whether the static target only emulates vectors, in which case a caller is better off
        /// with its own scalar code.
        HWY_INLINE bool isEmulated() {
          return HWY_TARGET == HWY_SCALAR || HWY_TARGET == HWY_EMU128;
        }

        /// The name of the target the ops below were compiled for.
        HWY_INLINE const char* targetName() { return hwy::TargetName(HWY_TARGET); }


        """

    for element in elements {
        output += "using \(element.tag) = hn::ScalableTag<\(element.cType)>;\n"
        output += "using \(element.vector) = hn::VFromD<\(element.tag)>;\n"
        output += "using \(element.mask) = hn::MFromD<\(element.tag)>;\n"
        output += "HWY_INLINE size_t \(referenceFunctionName("laneCount", element))()"
        output += " { return hn::Lanes(\(element.tag)()); }\n"
        output += portConversions(of: element)

        for op in ops where op.applies.matches(element) {
            let parameterBindings = bindings(of: op, for: element)
            let declarations =
                parameterBindings
                .filter { !$0.declaration.isEmpty }
                .map(\.declaration)
                .joined(separator: ", ")
            let arguments = parameterBindings.map(\.argument).joined(separator: ", ")
            let returnKeyword = op.returns == .void ? "" : "return "
            output += "HWY_INLINE \(referenceReturnType(op.returns, element)) "
            output += "\(referenceFunctionName(op.identifier, element))(\(declarations))"
            output += " { \(returnKeyword)hn::\(op.highwayName)(\(arguments)); }\n"
        }

        for op in wideningOps {
            for narrow in wideningSources(of: element) {
                let countDeclaration = op.takesCount ? ", size_t count" : ""
                let countArgument = op.takesCount ? ", count" : ""
                let narrowTag = "hn::Rebind<\(narrow.cType), \(element.tag)>()"
                output += "HWY_INLINE \(element.vector) "
                output += "\(wideningFunctionName(op, from: narrow, to: element))"
                output += "(const \(narrow.cType)* from\(countDeclaration))"
                output += " { return hn::PromoteTo(\(element.tag)(), "
                output += "hn::\(op.highwayName)(\(narrowTag), from\(countArgument))); }\n"
            }
        }

        let blockLanes = repeatingBlockLanes(of: element)
        output += "HWY_INLINE \(element.vector) "
        output += "\(referenceFunctionName(repeatingBlockName, element))("
        output += blockLanes.map { "\(element.cType) \($0)" }.joined(separator: ", ")
        output += ") { return hn::Dup128VecFromValues(\(element.tag)(), "
        output += "\(blockLanes.joined(separator: ", "))); }\n"
        output += "\n"
    }

    output += """
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
    vectorResult(compoundLiteral(element.cVector, repeatingBlockLanes(of: element)), for: element)
}

typealias TargetBranch = (condition: String, body: String)

let neonCondition = "CVECTORIZATION_OPS_NEON"

func mergingIdenticalBodies(_ branches: [TargetBranch]) -> [TargetBranch] {
    var merged: [TargetBranch] = []
    for branch in branches {
        if let previous = merged.last, previous.body == branch.body,
            previous.condition != neonCondition
        {
            merged[merged.count - 1] = branch
        } else {
            merged.append(branch)
        }
    }
    guard let neon = merged.first, neon.condition == neonCondition,
        let index = merged.lastIndex(where: {
            $0.body == neon.body && $0.condition != neonCondition
        })
    else { return merged }
    merged[index].condition = "\(neonCondition) || \(merged[index].condition)"
    return Array(merged.dropFirst())
}

func cBody<Input>(
    _ targets: TargetBodies<Input>,
    for input: Input,
    portable: String?
) -> String {
    let conditions = [
        (neonCondition, targets.neon),
        ("CVECTORIZATION_OPS_X86 >= 3", targets.sse4),
        ("CVECTORIZATION_OPS_X86 >= 2", targets.ssse3),
        ("CVECTORIZATION_OPS_X86 >= 1", targets.sse2),
    ]
    let branches = mergingIdenticalBodies(
        conditions.compactMap { condition, body in
            body?(input).map { (condition: condition, body: $0) }
        }
    )
    guard !branches.isEmpty else { return portable ?? "" }
    let chain = branches.enumerated().flatMap { index, branch in
        ["#\(index == 0 ? "if" : "elif") \(branch.condition)", branch.body]
            .filter { !$0.isEmpty }
    }
    let fallback = portable.map { ["#else", $0] } ?? []
    return (chain + fallback + ["#endif"]).joined(separator: "\n")
}

func cBody(of op: Op, for element: Element) -> String {
    cBody(op.targets, for: element, portable: op.portable(element))
}

func cHelpers(of op: Op, for element: Element) -> String {
    let helpers = cBody(op.helpers, for: element, portable: nil)
    return helpers.isEmpty ? "" : "\(helpers)\n"
}

func cBody(of op: WideningOp, from narrow: Element, to wide: Element) -> String {
    cBody(
        op.targets,
        for: (narrow, wide),
        portable: wideningBody(takesCount: op.takesCount, from: narrow, to: wide)
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

func rawVectorDeclarations() -> String {
    let groups = [("CVECTORIZATION_OPS_NEON", neonVectors), ("CVECTORIZATION_OPS_X86", x86Vectors)]
    return groups.map { condition, vectors in
        let typedefs = vectors.map {
            "typedef \($0.lane) \($0.name) __attribute__((\($0.attribute)));"
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
        case .vector, .indices, .fillVector, .otherwiseVector:
            return "const \(element.cVector) \(name) = (\(element.cVector))\(raw);"
        case .mask, .whereMask:
            return "const \(element.cMask) \(name) = (\(element.cMask))\(raw);"
        case .outVector:
            return "\(element.cVector)* const \(name) = (\(element.cVector)*)\(raw);"
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

func generateHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_VECTORIZATION_OPS_H
        #define SWIFT_VECTORIZATION_OPS_H

        #include <stdbool.h>
        #include <stddef.h>
        #include <stdint.h>

        #ifdef __cplusplus
        extern "C" {
        #endif

        #if defined(CVECTORIZATION_OPS_EXTERNAL_DEFINITIONS)
        #define CVECTORIZATION_OPS_INLINE extern inline __attribute__((always_inline))
        #define CVECTORIZATION_OPS_FUNCTION extern inline
        #else
        #define CVECTORIZATION_OPS_INLINE inline __attribute__((always_inline))
        #define CVECTORIZATION_OPS_FUNCTION inline
        #endif

        #if defined(CVECTORIZATION_OPS_PORTABLE)
        #define CVECTORIZATION_OPS_NEON 0
        #define CVECTORIZATION_OPS_X86 0
        #elif defined(__aarch64__)
        #define CVECTORIZATION_OPS_NEON 1
        #define CVECTORIZATION_OPS_X86 0
        #elif defined(__SSE4_2__)
        #define CVECTORIZATION_OPS_NEON 0
        #define CVECTORIZATION_OPS_X86 3
        #elif defined(__SSSE3__)
        #define CVECTORIZATION_OPS_NEON 0
        #define CVECTORIZATION_OPS_X86 2
        #elif defined(__SSE2__)
        #define CVECTORIZATION_OPS_NEON 0
        #define CVECTORIZATION_OPS_X86 1
        #else
        #define CVECTORIZATION_OPS_NEON 0
        #define CVECTORIZATION_OPS_X86 0
        #endif

        \(rawVectorDeclarations())

        \(x86Helpers())

        \(neonHelpers())

        /// Whether the target only emulates vectors, in which case a caller is better off
        /// with its own scalar code.
        CVECTORIZATION_OPS_INLINE bool cvectorization_ops_is_emulated(void) {
        #if CVECTORIZATION_OPS_NEON || CVECTORIZATION_OPS_X86 || defined(__ARM_NEON) || defined(__SSE2__) || \\
            defined(__ALTIVEC__) || defined(__VEC__) || defined(__loongarch_sx) ||               \\
            defined(__wasm_simd128__) || defined(__riscv_v)
          return false;
        #else
          return true;
        #endif
        }

        /// The name of the target the ops below were compiled for.
        CVECTORIZATION_OPS_INLINE const char* cvectorization_ops_target_name(void) {
        #if CVECTORIZATION_OPS_NEON
          return "NEON";
        #elif CVECTORIZATION_OPS_X86 >= 3
          return "SSE4";
        #elif CVECTORIZATION_OPS_X86 >= 2
          return "SSSE3";
        #elif CVECTORIZATION_OPS_X86 >= 1
          return "SSE2";
        #else
          return "EMU128";
        #endif
        }


        """

    for element in elements {
        output += """
            typedef \(element.cType) \(element.cVector) __attribute__((vector_size(16)));
            typedef \(element.cMaskLane) \(element.cMask) __attribute__((vector_size(16)));
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
            body: "return \(element.laneCount);"
        )
        output += cRawConversions(of: element)

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
        }

        for narrow in wideningSources(of: element) {
            let promotion = cBody(
                TargetBodies(sse2: { wide in x86PromotionHelper(from: narrow, to: wide) }),
                for: element,
                portable: nil
            )
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
            body: repeatingBlockBody(of: element),
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
    let name = binding.swiftName
    switch parameter {
    case .tag: return ""
    case .vector, .indices, .fillVector, .otherwiseVector:
        return element.hasOpaqueVector ? "\(name).raw" : name
    case .mask, .whereMask: return "\(name).raw"
    case .shiftAmount: return "Int32(truncatingIfNeeded: \(name))"
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
    case .vector, .indices, .outVector, .fillVector, .otherwiseVector:
        return "HighwayReference.\(element.vector)"
    case .mask, .whereMask: return "HighwayReference.\(element.mask)"
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

func swiftBody(of op: Op, for element: Element, arguments: String) -> String {
    let keyword = isUnsafe(op) ? "unsafe " : ""
    let call = "\(keyword)\(cFunctionName(op.identifier, element))(\(arguments))"
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
    var bridgeCall: (_ pointer: String, _ count: String) -> String
}

func spanForms(of op: Op, for element: Element) -> SpanForms? {
    guard let extent = op.span else { return nil }
    let parameterBindings = bindings(of: op, for: element)
    let takesCountFromSpan = if case .first = extent { true } else { false }

    var parameters: [SpanParameter] = []
    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        switch parameter {
        case .tag:
            continue
        case .count where takesCountFromSpan:
            continue
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
        parameters: parameters,
        returns: op.returns,
        extent: extent,
        element: "Lane",
        isMutable: op.parameters.contains(.lanePointer),
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
            return swiftBody(of: op, for: element, arguments: arguments.joined(separator: ", "))
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

    guard case .vectors(let count, let aligned) = forms.extent else {
        return """
                \(spanAvailability)
                @export(implementation) @inline(always)
                public static func \(forms.name)(\(checked.parameters))\(returnClause) {
                    span.\(accessor) { \(forms.bridgeCall("$0.baseAddress", "$0.count")) }
                }


            """
    }

    let unchecked = spanSignature(forms, label: spanLabel(forms, checked: false))
    let bridgeCall = forms.bridgeCall("$0.baseAddress.unsafelyUnwrapped", "$0.count")
    return checkedMembers(
        forms.name,
        availability: spanAvailability,
        checked: checked.parameters,
        unchecked: unchecked,
        returnClause: returnClause,
        checks: spanChecks(vectors: count, aligned: aligned),
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

/// The members of an op that takes a lane amount: a checked form that traps on an amount outside
/// `0...laneCount`, and an `@unsafe` unchecked one that only asserts it.
func laneAmountMembers(of op: Op, for element: Element) -> String {
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
        checks: laneAmountChecks(),
        uncheckedBody: "\(returnKeyword)\(body)"
    )
}

func laneAmountRequirements(of op: Op, indent: String) -> String {
    let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
    let unchecked = swiftSignature(of: op, for: elements[0], checked: false)
    return "\(indent)@unsafe static func \(op.swiftName)(\(unchecked.parameters))\(returnClause)\n"
}

func spanRequirements(_ forms: SpanForms, indent: String) -> String {
    let returnClause = forms.returns == .void ? "" : " -> \(swiftReturnType(forms.returns))"
    let checked = spanSignature(forms, label: spanLabel(forms, checked: true))
    var output = "\(indent)\(spanAvailability)\n"
    output += "\(indent)static func \(forms.name)(\(checked.parameters))\(returnClause)\n"
    guard case .vectors = forms.extent else { return output }
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
        if takesLaneAmount(op) {
            output += laneAmountRequirements(of: op, indent: indent)
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
        public var raw: \(element.cRawVector)

        @export(implementation) @inline(always)
        public init(raw: \(element.cRawVector)) {
            self.raw = raw
        }

        @export(implementation) @inline(always)
        public init(_ simd: \(element.swiftVector)) {
            raw = \(element.cToRawVector)(simd)
        }

        @export(implementation) @inline(always)
        public var simd: \(element.swiftVector) { \(element.cFromRawVector)(raw) }
    }
    """
}

func maskDeclaration(of element: Element) -> String {
    """
    public struct Mask: Sendable {
        public var raw: \(element.cRawMask)

        @export(implementation) @inline(always)
        public init(raw: \(element.cRawMask)) {
            self.raw = raw
        }

        @export(implementation) @inline(always)
        public init(_ simd: \(element.swiftMask)) {
            raw = \(element.cToRawMask)(simd._storage)
        }

        @export(implementation) @inline(always)
        public var simd: \(element.swiftMask) {
            \(element.swiftMask)(\(element.cFromRawMask)(raw))
        }
    }
    """
}

func typeDeclarations(of element: Element) -> String {
    let lane = "public typealias Lane = \(element.swiftType)"
    let mask = maskDeclaration(of: element)
    guard element.hasOpaqueVector else {
        return "\(lane)\npublic typealias Vector = \(element.swiftVector)\n\n\(mask)"
    }
    return "\(lane)\n\n\(vectorDeclaration(of: element))\n\n\(mask)"
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

    for op in ops where op.applies.matches(element) {
        if takesLaneAmount(op) {
            output += laneAmountMembers(of: op, for: element)
            continue
        }
        let signature = swiftSignature(of: op, for: element)
        let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
        let body = swiftBody(of: op, for: element, arguments: signature.arguments)
        output += "    @export(implementation) @inline(always)\n"
        output +=
            "    public static func \(op.swiftName)(\(signature.parameters))\(returnClause) {\n"
        output += "        \(body)\n"
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
        case .shiftAmount, .laneAmount, .indices: return true
        default: return false
        }
    }
}

func isAligned(_ op: Op) -> Bool {
    guard case .vectors(_, let aligned)? = op.span else { return false }
    return aligned
}

func pointerLanes(of op: Op, for element: Element) -> Int {
    switch op.span {
    case .vectors(let count, _)?: return count * element.laneCount
    case .first?: return element.laneCount
    case nil: fatalError("\(op.swiftName) takes a pointer but has no span extent")
    }
}

func pointerExpression(_ closureParameter: String, aligned: Bool) -> String {
    aligned ? closureParameter : "\(closureParameter).baseAddress!"
}

/// The lanes of `buffer` that a pointer op with `extent` may touch, which a guarded test puts right
/// before an inaccessible page.
func guardedLanes(of buffer: String, extent: SpanExtent?) -> String {
    guard case .first? = extent else { return buffer }
    return "Array(\(buffer).prefix(count))"
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
        case .indices:
            values = "Inputs.tableIndices(H.Vector.self, \(seed), inContract: \(inContract))"
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
            let lanes = pointerLanes(of: op, for: element)
            values = "Inputs.buffers(H.Lane.self, count: \(lanes), \(seed))"
        }
        inputs.append(ReferenceInput(parameter: parameter, name: binding.swiftName, values: values))
    }
    return inputs
}

let referenceCombinators = [2: "everyPair", 3: "mixedTriples", 4: "mixedQuadruples"]

func referenceLoop(over inputs: [ReferenceInput], for element: Element, test: String) -> String? {
    guard let first = inputs.first else { return nil }
    guard inputs.count > 1 else { return "for \(first.name) in \(first.name)Inputs" }
    guard let combinator = referenceCombinators[inputs.count] else {
        fatalError("\(test) has \(inputs.count) inputs, which nothing combines")
    }
    var arguments = inputs.map { "\($0.name)Inputs" }
    if inputs.count > 2 {
        arguments.append("seed: \(referenceTestSeed(element, test, "combinations"))")
    }
    let names = inputs.map(\.name).joined(separator: ", ")
    return "for (\(names)) in \(combinator)(\(arguments.joined(separator: ", ")))"
}

func referenceDescription(of inputs: [ReferenceInput], suffix: String = "") -> String {
    let fields = inputs.map { "\($0.name): \\(\($0.description))" }
    return "\"\(fields.joined(separator: ", "))\(suffix)\""
}

func portCall(_ name: String, _ arguments: [String], on type: String = "H") -> String {
    "\(type).\(name)(\(arguments.joined(separator: ", ")))"
}

func referenceCall(_ name: String, _ arguments: [String]) -> String {
    "HighwayReference.\(name)(\(arguments.joined(separator: ", ")))"
}

func referenceResult(_ call: String, returning returns: ReturnType) -> String {
    switch returns {
    case .vector, .mask: return "port(\(call))"
    default: return call
    }
}

func referenceCalls(
    of op: Op,
    for element: Element,
    pointer: String
) -> (port: String, reference: String) {
    var portArguments: [String] = []
    var referenceArguments: [String] = []
    var outVectorIndex = 0

    for (binding, parameter) in zip(bindings(of: op, for: element), op.parameters) {
        switch parameter {
        case .tag:
            continue
        case .vector, .indices, .mask, .fillVector, .whereMask, .otherwiseVector:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append("reference(\(binding.swiftName))")
        case .lane, .fillLane, .count, .shiftAmount, .laneAmount:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append(swiftArgument(binding, parameter, for: element))
        case .constLanePointer, .lanePointer:
            portArguments.append(swiftCallArgument(binding, passing: pointer))
            referenceArguments.append(pointer)
        case .outVector:
            portArguments.append(swiftCallArgument(binding, passing: "p\(outVectorIndex)"))
            referenceArguments.append("&r\(outVectorIndex)")
            outVectorIndex += 1
        }
    }

    let keyword = isUnsafe(op) ? "unsafe " : ""
    let call = referenceCall(referenceFunctionName(op.identifier, element), referenceArguments)
    let reference = referenceResult(call, returning: op.returns)
    let port = portCall(op.swiftName, op.swiftOrdered(portArguments))
    return ("\(keyword)\(port)", "\(keyword)\(reference)")
}

let emulatedShiftAttribute = """
    @Test(
        .disabled(
            if: SIMDTarget.targetName == "EMU128",
            "EMU128 has no defined result for these shift counts"
        )
    )
    """

func referenceTestFunction(
    _ test: String,
    label: String,
    for element: Element,
    inputs: [ReferenceInput],
    declarations: [String] = [],
    disabledOnEmulation: Bool = false,
    statements: String
) -> String {
    let header =
        disabledOnEmulation
        ? "\(emulatedShiftAttribute)\nfunc \(test)() {"
        : "@Test func \(test)() {"
    var lines = ["let mismatches = Mismatches(\"\(label)\")"]
    lines += inputs.map { "let \($0.name)Inputs = \($0.values)" }
    lines += declarations
    if let loop = referenceLoop(over: inputs, for: element, test: test) {
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

func referenceLoadStatements(
    of source: String,
    aligned: Bool,
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
            "unsafe withAlignedLanes(\(source)) { source in \(results) }.result"
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
    let zero = referenceCall(referenceFunctionName("zero", element), [])
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
        statements.append("mismatches.check(p\(index), port(r\(index)), \(description))")
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
            ? "let \(lanes) = unsafe withAlignedLanes(sentinel) \(closure).lanes"
            : "var \(lanes) = sentinel\n\(lanes).withUnsafeMutableBufferPointer \(closure)"
    }
    let comparison = "mismatches.check(portLanes, referenceLanes, \(description))"
    return (stores + [comparison]).joined(separator: "\n")
}

func referenceTest(
    of op: Op,
    for element: Element,
    inContract: Bool,
    guarded: Bool = false
) -> String {
    let (test, label) =
        if guarded {
            ("\(op.identifier)BeforeGuardPage", "\(op.identifier) before a guard page")
        } else if inContract {
            (op.identifier, op.identifier)
        } else {
            ("\(op.identifier)OutOfContract", "\(op.identifier) out of contract")
        }
    let inputs = referenceInputs(of: op, for: element, test: test, inContract: inContract)
    let description = referenceDescription(of: inputs)
    let aligned = isAligned(op)
    let isStore = op.parameters.contains(.lanePointer)
    let pointer = pointerExpression(isStore ? "destination" : "source", aligned: aligned || guarded)
    let calls = referenceCalls(of: op, for: element, pointer: pointer)
    var declarations: [String] = []
    let statements: String

    if let source = inputs.first(where: { $0.parameter == .constLanePointer })?.name {
        let outVectors = op.parameters.filter { $0 == .outVector }.count
        statements =
            outVectors == 0
            ? referenceLoadStatements(
                of: source,
                aligned: aligned,
                guardedLanes: guarded ? guardedLanes(of: source, extent: op.span) : nil,
                port: calls.port,
                reference: calls.reference,
                description: description
            )
            : referenceOutVectorStatements(
                of: source,
                count: outVectors,
                for: element,
                guardedLanes: guarded ? guardedLanes(of: source, extent: op.span) : nil,
                port: calls.port,
                reference: calls.reference,
                inputs: inputs
            )
    } else if isStore {
        let lanes = pointerLanes(of: op, for: element)
        let count = guarded ? "\(lanes)" : "\(lanes) + 4"
        declarations.append("let sentinel = Inputs.sentinel(H.Lane.self, count: \(count))")
        statements = referenceStoreStatements(
            aligned: aligned,
            guardedLanes: guarded ? guardedLanes(of: "sentinel", extent: op.span) : nil,
            port: calls.port,
            reference: calls.reference,
            description: description
        )
    } else {
        statements = "mismatches.check(\(calls.port), \(calls.reference), \(description))"
    }

    return referenceTestFunction(
        test,
        label: label,
        for: element,
        inputs: inputs,
        declarations: declarations,
        disabledOnEmulation: !inContract && op.parameters.contains(.shiftAmount),
        statements: statements
    )
}

func wideningReferenceTest(
    _ op: WideningOp,
    from narrow: Element,
    to wide: Element,
    guarded: Bool = false
) -> String {
    let name = "\(op.swiftName)From\(narrow.swiftType)"
    let test = guarded ? "\(name)BeforeGuardPage" : name
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
        inputs.append(
            ReferenceInput(
                parameter: .count,
                name: "count",
                values: "Inputs.bufferCounts(lanes: H.laneCount)"
            )
        )
        portArguments.append("count: count")
        referenceArguments.append("count")
    }

    let function = wideningFunctionName(op, from: narrow, to: wide)
    let reference = referenceResult(referenceCall(function, referenceArguments), returning: .vector)
    let suffix = guarded ? " before a guard page" : ""
    return referenceTestFunction(
        test,
        label: "\(op.swiftName) from \(narrow.swiftType)\(suffix)",
        for: wide,
        inputs: inputs,
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
    let reference = referenceResult(referenceCall(function, lanes), returning: .vector)
    let description = "\"lanes: \\(describe(vector))\""
    return referenceTestFunction(
        repeatingBlockName,
        label: repeatingBlockName,
        for: element,
        inputs: [vectors],
        statements: "mismatches.check(\(port), \(reference), \(description))"
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

func opaqueVector(_ expression: String, of element: Element) -> String {
    element.hasOpaqueVector ? "H.Vector(\(expression))" : expression
}

func referenceConformances(of element: Element) -> String {
    let mask = "extension \(element.namespace).Mask: ReferenceMask {}"
    guard element.hasOpaqueVector else { return mask }
    return "extension \(element.namespace).Vector: ReferenceVector {}\n\n\(mask)"
}

func generateReferenceTests(_ element: Element) -> String {
    var tests = [laneCountReferenceTest(for: element)]
    for op in ops where op.applies.matches(element) {
        tests.append(referenceTest(of: op, for: element, inContract: true))
        if hasOutOfContractInputs(op) {
            tests.append(referenceTest(of: op, for: element, inContract: false))
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
    let vectorForReference = referenceCall(
        referenceFunctionName("fromPort", element),
        [simdVector("vector", of: element)]
    )
    let vectorForPort = opaqueVector(
        referenceCall(referenceFunctionName("toPort", element), ["vector"]),
        of: element
    )
    let maskForReference = referenceCall(
        referenceFunctionName("maskFromPort", element),
        ["mask.simd._storage"]
    )
    let maskForPort = referenceCall(referenceFunctionName("maskToPort", element), ["mask"])

    return """
        \(generationNotice)

        import CHighwayReference
        import Vectorization
        import Testing

        \(referenceConformances(of: element))

        @Suite("\(element.namespace) against Highway")
        struct \(element.namespace)ReferenceTests {
            typealias H = \(element.namespace)

            func reference(_ vector: H.Vector) -> HighwayReference.\(element.vector) {
                \(vectorForReference)
            }

            func port(_ vector: HighwayReference.\(element.vector)) -> H.Vector {
                \(vectorForPort)
            }

            func reference(_ mask: H.Mask) -> HighwayReference.\(element.mask) {
                \(maskForReference)
            }

            func port(_ mask: HighwayReference.\(element.mask)) -> H.Mask {
                H.Mask(\(element.swiftMask)(\(maskForPort)))
            }

        \(tests.joined(separator: "\n\n"))
        }

        """
}

func uppercasedFirst(_ text: String) -> String {
    "\(text.prefix(1).uppercased())\(text.dropFirst())"
}

func codegenFunctionName(
    _ side: String,
    _ referenceName: String,
    constantParameter: String? = nil
) -> String {
    let suffix = constantParameter.map { "Constant\(uppercasedFirst($0))" } ?? ""
    return "\(side)\(uppercasedFirst(referenceName))\(suffix)"
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
            call: referenceKeyword + referenceCall(referenceName, reference.arguments)
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
        let callBindings = zip(bindings(of: op, for: element), op.parameters)
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
            return keyword + portCall(op.swiftName, labelled, on: element.namespace)
        case .highway:
            let reference = referenceFunctionName(op.identifier, element)
            return keyword + referenceCall(reference, op.highwayOrdered(arguments))
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
            return referenceCall(referenceFunctionName(repeatingBlockName, element), lanes)
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
    case .lane, .fillLane: return (lane, lane)
    case .shiftAmount: return ("3", "3")
    case .laneAmount, .count: return ("1", "1")
    case .tag, .mask, .whereMask, .constLanePointer, .lanePointer, .outVector: return nil
    }
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
    let constants = parameters.indices.filter {
        codegenConstant(of: parameters[$0].kind, for: element) != nil
    }
    let variants: [Int?] = [nil] + constants
    var functions: [String] = []

    for variant in variants {
        var portParameters: [String] = []
        var referenceParameters: [String] = []
        var portArguments: [String] = []
        var referenceArguments: [String] = []

        for (index, parameter) in parameters.enumerated() {
            let binding = parameter.binding
            if index == variant, let constant = codegenConstant(of: parameter.kind, for: element) {
                portArguments.append(swiftCallArgument(binding, passing: constant.port))
                referenceArguments.append(constant.reference)
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
                binding.isInOut ? "&\(binding.swiftName)" : binding.swiftName
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

func codegenFunctions(of op: Op, for element: Element) -> String {
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

    return codegenFunctions(
        op.swiftName,
        referenceName: referenceFunctionName(op.identifier, element),
        for: element,
        returns: op.returns,
        isUnsafe: (port: isUnsafe(op) || takesLaneAmount(op), reference: isUnsafe(op)),
        parameters: op.swiftOrdered(parameters),
        highwayOrdered: op.highwayOrdered
    )
}

func codegenFunctions(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
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

    return codegenFunctions(
        op.swiftName,
        referenceName: wideningFunctionName(op, from: narrow, to: wide),
        for: wide,
        returns: .vector,
        isUnsafe: (port: true, reference: true),
        parameters: parameters
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
                arguments.append(binding.isInOut ? "&\(binding.swiftName)" : binding.swiftName)
            }
        }
        return "unsafe \(referenceCall(referenceFunctionName(op.identifier, element), arguments))"
    }
    return forms
}

func referenceSpanForms(of op: WideningOp, from narrow: Element, to wide: Element) -> SpanForms {
    var forms = spanForms(of: op, from: narrow, to: wide)
    let function = wideningFunctionName(op, from: narrow, to: wide)
    forms.bridgeCall = { pointer, count in
        "unsafe \(referenceCall(function, op.takesCount ? [pointer, count] : [pointer]))"
    }
    return forms
}

/// Highway's ops behind the same span members as the port's, so that kernels take spans on both
/// sides.
func referenceSpanNamespace(of element: Element) -> String {
    var output = """
        public enum \(referenceNamespace(of: element)) {
            public typealias Lane = \(element.swiftType)
            public typealias Vector = HighwayReference.\(element.vector)

            @export(implementation) @inline(always)
            public static var laneCount: Int {
                Int(\(referenceCall(referenceFunctionName("laneCount", element), [])))
            }


        """
    for op in ops where op.applies.matches(element) {
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

struct CodegenKernel {
    let name: String
    let applies: Applies
    let returns: ReturnType
    let parameters: (CodegenSide) -> [String]
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
        parameters: { side in ["_ v: \(side.vector)"] },
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
        parameters: { side in ["_ v: \(side.vector)"] },
        body: { side in
            let digits = codegenDigitValues(of: "v", on: side)
            return (digits.statements + ["return \(digits.result)"]).joined(separator: "\n")
        }
    ),
    CodegenKernel(
        name: "NoneAbove",
        applies: .integer,
        returns: .boolean,
        parameters: { side in ["_ v: \(side.vector)"] },
        body: { side in
            let above = side.call("greaterThan", ["v", side.repeating("26")])
            return "return \(side.call("allFalse", [above]))"
        }
    ),
    CodegenKernel(
        name: "SmallestAtLeast",
        applies: .unsigned(bits: [32]),
        returns: .lane,
        parameters: { side in ["from: \(side.pointer)", "count: Int", "atLeast n: \(side.lane)"] },
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
        parameters: { side in ["from: \(side.pointer)", "count: Int"] },
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
        parameters: { side in ["_ input: \(side.vector)"] },
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
        parameters: { side in ["atLeast n: \(side.lane)", "in values: Span<\(side.lane)>"] },
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
        parameters: { side in ["_ inputBytesSpan: Span<\(side.lane)>"] },
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
        parameters: { side in
            ["span: Span<\(side.lane)>", "into output: inout OutputSpan<\(side.lane)>"]
        },
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
        parameters: { side in ["_ bytes: Span<\(side.lane)>"] },
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
        parameters: { _ in ["_ bytes: Span<UInt8>"] },
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
            parameters: kernel.parameters(side),
            returnClause: " -> \(side.returnType(kernel.returns))",
            call: kernel.body(side)
        )
        return kernel.usesSpans ? "\(spanAvailability)\n\(function)" : function
    }
    return functions.joined(separator: "\n\n")
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
try write(generateHeader(), to: headerPath)
try write(generateReferenceHeader(), to: referenceHeaderPath)
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
}
try format(generatedSwiftRoot)
try format(generatedReferenceTestsRoot)
try format(generatedCodegenRoot)
FileHandle.standardError.write(
    Data("** ✅ Generated \(elements.count) element types.\n".utf8)
)
