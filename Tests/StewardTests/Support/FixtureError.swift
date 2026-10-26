/// A fixture the tests need couldn't be built or found.
struct FixtureError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
