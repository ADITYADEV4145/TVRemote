/// What the current TV can do, so commands are understood for this TV.
public struct VoiceContext: Sendable {
    public var catalog: AppCatalog
    /// The TV accepts a content search (Roku's /search, for example).
    public var supportsSearch: Bool

    public init(catalog: AppCatalog = .standard, supportsSearch: Bool = true) {
        self.catalog = catalog
        self.supportsSearch = supportsSearch
    }
}
