extension GitRepository {
    /// An object as `git cat-file --batch` prints it.
    struct BatchObject: Sendable, Hashable {
        /// `blob` for a file's contents.
        var type: String
        var bytes: [UInt8]
    }

    /// The objects named `objects`, full object IDs, by ID.
    func objects(_ objects: [String]) async throws -> [String: BatchObject] {
        guard !objects.isEmpty else { return [:] }
        let arguments = ["cat-file", "--batch"]
        let outcome = try await git.run(
            arguments,
            input: Array(objects.map { "\($0)\n" }.joined().utf8),
            into: [UInt8]()
        ) { $0.append(contentsOf: $1) }
        try Git.requireSuccess(outcome, arguments)
        guard let parsed = Self.batch(outcome.output, of: objects) else {
            throw ContextError.unexpectedGitOutput(
                arguments: arguments,
                reason: "it printed something other than the \(objects.count) objects it was asked for"
            )
        }
        return parsed
    }

    /// The objects `cat-file --batch` printed for `objects`, or nil when the
    /// output isn't each of them in turn: for each,
    /// `<object> SP <type> SP <size> LF`, then the contents and LF. A
    /// missing object, which git prints as `<object> SP missing LF`, makes
    /// it nil too.
    static func batch(_ output: [UInt8], of objects: [String]) -> [String: BatchObject]? {
        var parsed: [String: BatchObject] = [:]
        var cursor = output.startIndex
        // Imperative: a cursor through the output, whose headers say where
        // each object's contents end.
        for object in objects {
            guard let newline = output[cursor...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let header = output[cursor..<newline].split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
            let start = newline + 1
            guard header.count == 3, header[0].elementsEqual(object.utf8), let size = decimal(header[2]),
                  // The contents and the line break after them, compared
                  // so that no size can overflow.
                  size < output.endIndex - start, output[start + size] == UInt8(ascii: "\n")
            else { return nil }
            parsed[object] = BatchObject(
                type: String(decoding: header[1], as: UTF8.self),
                bytes: Array(output[start..<start + size])
            )
            cursor = start + size + 1
        }
        return cursor == output.endIndex ? parsed : nil
    }
}
