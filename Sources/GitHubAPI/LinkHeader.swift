import Foundation

/// GitHub's `link` response header, which points a paginated list at its
/// neighboring pages: `<…&page=2>; rel="next", <…&page=9>; rel="last"`.
enum LinkHeader {
    /// Whether `value` points at a next page. Accepts a quoted or bare
    /// `rel`, and a `rel` that lists several relations.
    static func namesNextPage(_ value: String) -> Bool {
        value.split(separator: ",").contains { link in
            link.split(separator: ";").dropFirst().contains { parameter in
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else {
                    return false
                }
                return pair[1]
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
                    .lowercased()
                    .split(separator: " ")
                    .contains("next")
            }
        }
    }
}
