/// Maps line numbers in the built commit, the tree a build log comes from,
/// to the pull request's head commit.
///
/// A `pull_request` workflow builds the merge commit Actions checks out,
/// not the head. The two agree on a file unless the base branch changed it
/// above the pull request's edits, which shifts every line below. Steward
/// reports in head coordinates, so it maps each log line first.
///
/// Read from `git diff -U0 -M <head> <built>` over the whole tree: a line
/// outside every hunk shifts by the hunks above it; a line inside one, which
/// the base or the merge changed, has no counterpart in the head. A file the
/// base renamed maps back through the rename. Paths are decoded lossily, as
/// in `GitChanges`' file lists.
public struct LineMap: Sendable, Hashable {
    /// How one file of the built commit differs from the head.
    struct File: Sendable, Hashable {
        /// Nil when the head has no counterpart: the file is new in the
        /// built commit, or its diff was too damaged to read.
        var headPath: String?
        /// Nil when no line maps: a binary file, or offsets beyond `Int`.
        var shifts: [Shift]?
    }

    /// One hunk of the head-to-built diff, in built-commit lines.
    struct Shift: Sendable, Hashable {
        /// The first built line the hunk affects. For a hunk that only
        /// removes head lines, the line after the removal.
        var start: Int
        /// The first built line after the hunk; equal to `start` when the
        /// hunk only removes head lines.
        var end: Int
        /// Head line minus built line, from `end` on.
        var offset: Int
    }

    /// The files of the built commit that differ from the head, by path.
    var files: [String: File]

    /// The map for a built commit that is the head: every line maps to
    /// itself.
    public static let identity = LineMap(files: [:])

    /// The head commit's path for the built commit's file at `path`: the
    /// same path, or where the file was before the base renamed it; nil
    /// when the head has no such file.
    public func headPath(ofFile path: String) -> String? {
        guard let file = files[path] else { return path }
        return file.headPath
    }

    /// The head commit's location for line `line` of the built commit's
    /// file at `path`, or nil when the head has no counterpart: the base or
    /// the merge changed the line, the file is new or binary, or the line
    /// number is below 1.
    ///
    /// Line numbers past a file's end aren't detected: they map like the
    /// lines above them.
    public func headLocation(ofLine line: Int, inFile path: String) -> Location? {
        guard line >= 1 else { return nil }
        guard let file = files[path] else { return Location(path: path, line: line) }
        guard let headPath = file.headPath,
              let shifts = file.shifts,
              let headLine = Self.headLine(ofBuiltLine: line, shifts: shifts)
        else { return nil }
        return Location(path: headPath, line: headLine)
    }

    /// `shifts` must be sorted by `start`.
    static func headLine(ofBuiltLine line: Int, shifts: [Shift]) -> Int? {
        // A binary search for the last shift that starts at or before `line`,
        // so a lookup costs O(log hunks) however many lines a log has.
        var low = 0
        var high = shifts.count
        while low < high {
            let middle = low + (high - low) / 2
            if shifts[middle].start <= line {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return line }
        let shift = shifts[low - 1]
        guard line >= shift.end else { return nil }
        // Log line numbers are untrusted: a huge one mustn't trap.
        let (headLine, overflow) = line.addingReportingOverflow(shift.offset)
        return overflow || headLine < 1 ? nil : headLine
    }
}
