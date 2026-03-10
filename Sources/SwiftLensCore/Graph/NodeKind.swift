/// All symbol kinds tracked in the knowledge graph.
public enum NodeKind: String, Codable, Sendable, CaseIterable {
    case module
    case file
    case `struct`
    case `class`
    case `enum`
    case `protocol`
    case actor
    case `extension`
    case function
    case variable
    case initializer
    case typeAlias
    case enumCase
    case macro
}
