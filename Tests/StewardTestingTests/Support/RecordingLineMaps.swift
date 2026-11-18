import StewardTesting

/// A reader that records each line map it's asked for, then answers
/// through another.
///
/// Here rather than in `FakeRepositoryFiles`: recording needs a reference
/// type the fake would carry as public API, for a check only Steward's
/// own tests make.
struct RecordingLineMaps: RepositoryFiles {
    /// The maps asked for, each as its `built`, `head` and `mergeBase`.
    actor Requests {
        private(set) var all: [[String]] = []

        func record(_ request: [String]) {
            all.append(request)
        }
    }

    let requests = Requests()
    let files: FakeRepositoryFiles

    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        try await files.contents(ofFileAt: path, in: commit, limit: limit)
    }

    func commit(named name: String) async throws -> String? {
        try await files.commit(named: name)
    }

    func lineMap(from built: String, to head: String, attributesFrom mergeBase: String) async throws -> LineMap {
        await requests.record([built, head, mergeBase])
        return try await files.lineMap(from: built, to: head, attributesFrom: mergeBase)
    }
}
