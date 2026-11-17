/// What a read of one path in one commit found: the file's bytes, or why
/// there are none.
///
/// Minor releases may add cases, so a `switch` over one needs an
/// `@unknown default`.
#if hasAttribute(nonexhaustive)
@nonexhaustive
#endif
public enum FileContents: Sendable, Hashable {
    /// A regular file's bytes, exactly as committed: no line-ending or
    /// encoding conversion, no filters.
    case bytes([UInt8])
    /// Nothing is at the path in that commit, or the path can't name a
    /// file: it's empty or absolute, or has an empty, `.` or `..`
    /// component.
    case noSuchFile
    /// Something other than a regular file is at the path: a symbolic link,
    /// a submodule, or a directory. Nothing is read, so a link never leads
    /// a read out of the commit.
    case notRegularFile
    /// A regular file of `size` bytes, more than the limit, so it wasn't
    /// read.
    case tooLarge(size: Int)

    /// The size limit of a read that doesn't give its own: 1 MiB, or
    /// 1,048,576 bytes.
    public static let defaultLimit = 1 << 20
}
