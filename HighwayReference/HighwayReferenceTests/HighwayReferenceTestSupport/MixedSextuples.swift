package func mixedSextuples<A, B, C, D, E, F>(
    _ first: [A],
    _ second: [B],
    _ third: [C],
    _ fourth: [D],
    _ fifth: [E],
    _ sixth: [F],
    seed: UInt64
) -> [(A, B, C, D, E, F)] {
    var generator = SplitMix64(seed: seed)
    return everyPair(first, second).map { a, b in
        (
            a, b, third[Int(generator.next() % UInt64(third.count))],
            fourth[Int(generator.next() % UInt64(fourth.count))],
            fifth[Int(generator.next() % UInt64(fifth.count))],
            sixth[Int(generator.next() % UInt64(sixth.count))]
        )
    }
}
