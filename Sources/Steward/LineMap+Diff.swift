import GitDiffKit

extension LineMap {
    /// Reads the map from the built commit's lines to the head's from
    /// `diff`, whose old side is the head and whose new side is the built
    /// commit: `git diff -U0 -M <head> <built>`, in that order.
    ///
    /// For a test of a rule that maps a build log's lines, with
    /// `FakeLocalRepository(_:lineMaps:)`. A diff in the other order maps
    /// the other way, so it reads without complaint and maps wrong. A diff
    /// with context lines reads too, but only `-U0` gives the map a run
    /// reads: without context, git trims the end the two files share
    /// before it diffs them, so with context it can align a repeated line,
    /// such as a blank one, elsewhere, and the line maps to another or to
    /// none. A run also diffs with git's default algorithm and indent
    /// heuristic, whatever `diff.algorithm` and `diff.indentHeuristic`
    /// say. A file whose diff is too damaged to read maps no line.
    public init(diff: String) {
        var parser = DiffEventParser(consumer: Collector())
        parser.consume(diff)
        self = parser.finalize().map
    }
}
