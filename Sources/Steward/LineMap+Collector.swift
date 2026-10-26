import GitDiffKit

extension LineMap {
    /// Collects a map from the events of a diff whose old side is the head
    /// and whose new side is the built commit.
    ///
    /// Keeps only file headers and hunk headers, so memory doesn't grow
    /// with the lines the base changed, however far it moved.
    struct Collector: DiffEventConsumer, Sendable {
        private(set) var map = LineMap(files: [:])
        private var header: FileHeader?
        private var hunks: [HunkHeader] = []

        mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
            endFile()
            self.header = header
        }

        mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>) {
            hunks.append(header)
        }

        mutating func endFile() {
            if let header, let builtPath = header.newPath?.string {
                map.files[builtPath] = Self.file(header, hunks: hunks)
            }
            header = nil
            hunks = []
        }

        /// An abandoned file would otherwise look unchanged, mapping every
        /// line to itself.
        mutating func damage(_ report: DamageReport) {
            guard report.severity == .error, let builtPath = report.file?.newPath?.string else { return }
            map.files[builtPath] = File(headPath: nil, shifts: nil)
        }

        /// A deleted file has no built path, so it never gets here.
        private static func file(_ header: FileHeader, hunks: [HunkHeader]) -> File {
            switch header.change {
            case .added, .copied, .deleted:
                return File(headPath: nil, shifts: nil)
            case .modified, .renamed:
                return File(
                    headPath: (header.oldPath ?? header.newPath)?.string,
                    shifts: header.isBinary ? nil : shifts(hunks)
                )
            }
        }

        /// Nil when the offsets overflow, which only a hostile diff can
        /// make them do.
        private static func shifts(_ hunks: [HunkHeader]) -> [Shift]? {
            let spans = hunks
                .map { hunk in
                    // A hunk that adds no built lines sits after line
                    // `newStart`, which git counts from 0.
                    hunk.newCount > 0
                        ? (start: hunk.newStart, end: hunk.newStart + hunk.newCount, hunk: hunk)
                        : (start: hunk.newStart + 1, end: hunk.newStart + 1, hunk: hunk)
                }
                .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            let folded = spans.reduce(into: (shifts: [Shift](), offset: 0, overflow: false)) { result, span in
                let (step, stepOverflow) = span.hunk.oldCount.subtractingReportingOverflow(span.hunk.newCount)
                let (offset, offsetOverflow) = result.offset.addingReportingOverflow(step)
                result.overflow = result.overflow || stepOverflow || offsetOverflow
                result.offset = offset
                result.shifts.append(Shift(start: span.start, end: span.end, offset: offset))
            }
            return folded.overflow ? nil : folded.shifts
        }
    }
}
