/// A reader's answer when it has no map between two commits: one that
/// gives no line maps, or StewardTesting's fake, which holds only those a
/// test gives it.
package struct MissingLineMap: Error, CustomStringConvertible {
    package var built: String
    package var head: String

    package init(built: String, head: String) {
        self.built = built
        self.head = head
    }

    package var description: String {
        "The reader has no map from the lines of \(built) to those of \(head)."
    }
}
