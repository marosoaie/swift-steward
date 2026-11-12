extension String {
    /// The string with its control characters (C0, DEL and C1) other than
    /// `kept` written as Swift escapes, such as `\u{1B}`, for output people
    /// read in a terminal: text from a pull request or a log can't move the
    /// cursor, change colours, or break a line where it shouldn't. A
    /// `\u{1B}` the text holds literally reads the same; machine-readable
    /// output, such as JSON, has its own escaping instead.
    package func escapingControlCharacters(except kept: Set<Unicode.Scalar>) -> String {
        let isEscaped = { (scalar: Unicode.Scalar) in
            scalar.properties.generalCategory == .control && !kept.contains(scalar)
        }
        guard unicodeScalars.contains(where: isEscaped) else { return self }
        return unicodeScalars.reduce(into: "") { escaped, scalar in
            if isEscaped(scalar) {
                escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
    }
}
