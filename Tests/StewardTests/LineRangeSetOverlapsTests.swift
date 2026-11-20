import GitDiffKit
import Steward
import Testing

/// `LineRangeSet.overlaps(_:)` against a scan of every range.
@Suite("Whether a range of lines overlaps a set of them")
struct LineRangeSetOverlapsTests {
    static let set = LineRangeSet([3...5, 10...10, 20...30])

    @Test("a range overlaps where it shares a line, edges and extremes included", arguments: [
        (1...2, false), (1...3, true), (5...9, true), (6...9, false), (4...4, true), (10...10, true),
        (11...19, false), (9...11, true), (30...31, true), (31...40, false), (Int.min...Int.max, true),
        (Int.min...2, false), (Int.max...Int.max, false), (Int.min...Int.min, false), (0...100, true),
    ])
    func cases(lineRange: ClosedRange<Int>, overlaps: Bool) {
        #expect(Self.set.overlaps(lineRange) == overlaps)
    }

    @Test("an empty set overlaps nothing, and a set at Int's ends is found there")
    func extremes() {
        #expect(!LineRangeSet().overlaps(Int.min...Int.max))
        let ends = LineRangeSet([Int.min...Int.min, Int.max...Int.max])
        #expect(ends.overlaps(Int.max...Int.max))
        #expect(ends.overlaps(Int.min...0))
        #expect(!ends.overlaps(Int.min + 1...Int.max - 1))
    }

    @Test("it answers as a scan of every range does, on seeded random sets", arguments: 0..<20)
    func oracle(seed: UInt64) {
        var generator = SplitMix(seed: seed)
        let set = LineRangeSet((0..<Int.random(in: 0...12, using: &generator)).map { _ in
            let start = Int.random(in: 1...200, using: &generator)
            return start...start + Int.random(in: 0...6, using: &generator)
        })
        let disagreements = (0..<300).compactMap { _ -> ClosedRange<Int>? in
            let start = Int.random(in: -5...210, using: &generator)
            let lineRange = start...start + Int.random(in: 0...15, using: &generator)
            return set.overlaps(lineRange) == set.ranges.contains { $0.overlaps(lineRange) } ? nil : lineRange
        }
        #expect(disagreements.isEmpty, "\(set.ranges)")
    }
}

/// A seeded generator, so a failing seed reruns as it failed.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
