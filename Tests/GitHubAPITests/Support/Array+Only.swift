extension Array {
    /// The element, when there is exactly one.
    var only: Element? {
        count == 1 ? first : nil
    }
}
