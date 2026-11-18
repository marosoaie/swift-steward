import GitDiffKit

extension LineMap {
    /// Reads the map from the built commit's lines to the head's from
    /// `diff`, whose old side is the head and whose new side is the built
    /// commit: `git diff -M <head> <built>`, in that order.
    ///
    /// For a test of a rule that maps a build log's lines, with
    /// `FakeRepositoryFiles(_:lineMaps:)`. A diff in the other order maps
    /// the other way, so it reads without complaint and maps wrong. Context
    /// lines don't change the map, so git's default diff and `-U0` read
    /// alike. A file whose diff is too damaged to read maps no line.
    public init(diff: String) {
        var parser = DiffEventParser(consumer: Collector())
        parser.consume(diff)
        self = parser.finalize().map
    }
}
