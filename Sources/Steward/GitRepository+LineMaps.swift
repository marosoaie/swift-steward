extension GitRepository {
    func commit(named name: String) async throws -> String? {
        try await git.commit(named: name)
    }

    func lineMap(from built: String, to head: String, attributesFrom mergeBase: String) async throws -> LineMap {
        try await LineMap(built: built, head: head, attributesFrom: mergeBase, git: git)
    }
}
