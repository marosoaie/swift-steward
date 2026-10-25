/// An API token that prints as `<redacted>` everywhere: in descriptions, in
/// debug output, and in `dump`, which walks the mirrors of everything that
/// holds it.
struct Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: String

    var description: String {
        "<redacted>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
