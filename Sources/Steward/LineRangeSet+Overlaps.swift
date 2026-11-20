import GitDiffKit

extension LineRangeSet {
    /// Whether any line of `lineRange` is in the set: whether a declaration
    /// that spans `lineRange`, say, overlaps the changes.
    ///
    /// A binary search, O(log n) in the number of ranges.
    public func overlaps(_ lineRange: ClosedRange<Int>) -> Bool {
        // Imperative: a binary search, for the first range that doesn't
        // end before `lineRange` starts.
        var low = ranges.startIndex
        var high = ranges.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if ranges[middle].upperBound < lineRange.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.endIndex && ranges[low].lowerBound <= lineRange.upperBound
    }
}
