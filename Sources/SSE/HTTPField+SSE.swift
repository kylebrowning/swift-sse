public import HTTPTypes

extension HTTPField.Name {
    /// The `Last-Event-ID` header that an `EventSource` sends when it connects again.
    public static let lastEventID = HTTPField.Name("Last-Event-ID")!
}
