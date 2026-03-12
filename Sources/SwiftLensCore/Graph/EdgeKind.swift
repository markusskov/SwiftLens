/// All relationship types in the knowledge graph.
public enum EdgeKind: String, Codable, Sendable, CaseIterable {
    case contains          // parent → child member
    case imports           // file → module
    case conformsTo        // type → protocol
    case inherits          // class → superclass
    case extends           // extension → base type
    case composesView      // SwiftUI view → child view
    case usesEnvironment   // view → @Environment key
    case declaresEnvironment // type → EnvironmentKey declaration
    case dependsOn         // module → module
    case references        // symbol → referenced symbol
    case calls             // function → called function
    case appliesWrapper    // property → wrapper type
    case overrides         // method → overridden superclass method
    case implementsRequirement // concrete method → protocol requirement
}
