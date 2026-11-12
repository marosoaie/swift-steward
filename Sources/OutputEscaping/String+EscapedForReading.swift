extension String {
    /// The string as output people read shows it: control characters (C0,
    /// DEL and C1) other than `kept` written as Swift escapes, such as
    /// `\u{1B}`, and the syntax of a GitHub Actions workflow command broken
    /// the same way, `##[` as `#\u{23}[` and a `::` that starts a line,
    /// after any whitespace, as `\u{3A}:`.
    ///
    /// Text from a pull request or a log then can't move the cursor, change
    /// colours, break a line where it shouldn't, or pass for a command when
    /// the output lands in a workflow's log. A line starts at the string's
    /// start and after a kept `\n` or `\r`. A `\u{1B}` the text holds
    /// literally reads the same; machine-readable output, such as JSON, has
    /// its own escaping instead.
    package func escapedForReading(keeping kept: Set<Unicode.Scalar>) -> String {
        let escape = { (scalar: Unicode.Scalar) in "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" }
        // Scalars, not Characters: the runner reads UTF-16, so a combining
        // mark after `[` or `:` doesn't hide the command from it.
        return unicodeScalars.reduce(into: (text: "", line: LinePosition.blank)) { state, scalar in
            let isControl = scalar.properties.generalCategory == .control
            if isControl, !kept.contains(scalar) {
                state.text += escape(scalar)
                state.line = .text
            } else if isControl, scalar == "\n" || scalar == "\r" {
                state.text.unicodeScalars.append(scalar)
                state.line = .blank
            } else if scalar == "[", state.text.unicodeScalars.suffix(2).elementsEqual(["#", "#"]) {
                state.text.unicodeScalars.removeLast()
                state.text += "\(escape("#"))["
                state.line = .text
            } else if scalar == ":", state.line == .leadingColon {
                state.text.unicodeScalars.removeLast()
                state.text += "\(escape(":")):"
                state.line = .text
            } else {
                state.text.unicodeScalars.append(scalar)
                state.line = switch (state.line, scalar) {
                case (.blank, ":"): .leadingColon
                case (.blank, _) where scalar.properties.isWhitespace: .blank
                default: .text
                }
            }
        }.text
    }
}

/// Where a scalar falls in its line, for finding a `::` that starts one.
private enum LinePosition {
    /// Only whitespace since the line started.
    case blank
    /// Just after a `:` that follows only whitespace.
    case leadingColon
    case text
}
