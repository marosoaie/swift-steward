import GitDiffKit

extension LineMap {
    /// Reads the map from `diff`, the diff from the head commit to the
    /// built commit as `git diff -U0 -M <head> <built>` writes it.
    ///
    /// For a test of a rule that maps a build log's lines, with
    /// `FakeRepositoryFiles(_:lineMaps:)`. Only file and hunk headers
    /// count, so write the diff without context lines, as a run reads it:
    /// a context line would count as one the base changed. A file whose
    /// diff is too damaged to read maps no line.
    public init(diff: String) {
        var parser = DiffEventParser(consumer: Collector())
        parser.consume(diff)
        self = parser.finalize().map
    }
}
