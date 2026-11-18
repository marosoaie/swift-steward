import GitDiffKit

extension LineMap {
    /// Collects a map from the events of a diff whose old side is the head
    /// and whose new side is the built commit.
    ///
    /// Keeps each file's runs of changed lines, not the lines, so memory
    /// doesn't grow with the lines the base changed, however far it moved.
    /// A context line ends a run, so a diff with context maps as its `-U0`
    /// twin does, whose hunks are the runs.
    struct Collector: DiffEventConsumer, Sendable {
        private(set) var map = LineMap(files: [:])
        private var header: FileHeader?
        /// The file's runs of changed lines so far, each a shift whose
        /// offset is its own, not yet added to those of the runs above it.
        private var changes: [Shift] = []
        /// The built line of the hunk's next context or added line.
        private var builtLine = 0
        /// Where the run of changed lines in progress starts, and how many
        /// head lines it has removed so far.
        private var run: (start: Int, removed: Int)?
        /// The built paths of files with a hunk cut short.
        private var cutShort: Set<String> = []

        mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
            endFile()
            self.header = header
        }

        mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>) {
            endRun()
            // A hunk that adds no built lines sits after line `newStart`,
            // which git counts from 0. Hunk headers stop at 2⁴⁸, so
            // counting from there can't overflow.
            builtLine = header.newCount > 0 ? header.newStart : header.newStart + 1
        }

        mutating func line(_ line: LineInfo, content: Span<UInt8>) {
            if line.kind == .context {
                endRun()
            } else if run == nil {
                run = (builtLine, 0)
            }
            if line.kind == .deletion {
                run?.removed += 1
            } else {
                builtLine += 1
            }
        }

        mutating func endFile() {
            endRun()
            if let header, let builtPath = header.newPath?.string {
                map.files[builtPath] = Self.file(header, changes: changes)
                if cutShort.contains(builtPath) { map.files[builtPath]?.shifts = nil }
            }
            header = nil
            changes = []
        }

        /// An abandoned file would otherwise look unchanged, mapping every
        /// line to itself. A hunk cut short ends before the lines its
        /// header counts, so neither says where the base's change ends:
        /// none of its file's lines map.
        mutating func damage(_ report: DamageReport) {
            guard let builtPath = report.file?.newPath?.string else { return }
            if report.severity == .error {
                map.files[builtPath] = File(headPath: nil, shifts: nil)
            } else if report.reason == .hunkCutShort {
                cutShort.insert(builtPath)
                map.files[builtPath]?.shifts = nil
            }
        }

        private mutating func endRun() {
            if let run {
                // Hunk headers stop at 2⁴⁸, so neither difference overflows.
                changes.append(Shift(start: run.start, end: builtLine, offset: run.removed - (builtLine - run.start)))
            }
            run = nil
        }

        /// A deleted file has no built path, so it never gets here.
        private static func file(_ header: FileHeader, changes: [Shift]) -> File {
            switch header.change {
            case .added, .copied, .deleted:
                return File(headPath: nil, shifts: nil)
            case .modified, .renamed:
                return File(
                    headPath: (header.oldPath ?? header.newPath)?.string,
                    shifts: header.isBinary ? nil : shifts(changes)
                )
            }
        }

        /// Nil when the offsets overflow, which only a hostile diff can
        /// make them do.
        private static func shifts(_ changes: [Shift]) -> [Shift]? {
            let sorted = changes.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            let folded = sorted.reduce(into: (shifts: [Shift](), offset: 0, overflow: false)) { result, change in
                let (offset, overflow) = result.offset.addingReportingOverflow(change.offset)
                result.overflow = result.overflow || overflow
                result.offset = offset
                result.shifts.append(Shift(start: change.start, end: change.end, offset: offset))
            }
            return folded.overflow ? nil : folded.shifts
        }
    }
}
