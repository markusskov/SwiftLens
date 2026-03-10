import SwiftSyntax

/// Extracts type references from declarations for building usage edges.
///
/// Visits every `IdentifierTypeSyntax` node in the AST, which captures type references
/// in function parameters, return types, property type annotations, generic arguments,
/// enum case associated values, and typealias targets.
final class TypeReferenceVisitor: SyntaxVisitor {
    var typeReferences: [ExtractedTypeReference] = []

    private let converter: SourceLocationConverter
    private var contextStack: [String] = []

    /// Swift standard library and common framework types to skip.
    /// These won't be in the project's symbol table, so filtering them early avoids
    /// unnecessary DB lookups during resolution.
    private static let builtinTypes: Set<String> = [
        // Swift primitives
        "String", "Int", "Double", "Float", "Bool", "Character", "Void",
        "UInt", "Int8", "Int16", "Int32", "Int64",
        "UInt8", "UInt16", "UInt32", "UInt64",
        // Collections & wrappers
        "Array", "Dictionary", "Set", "Optional", "Result",
        // Special types
        "Any", "AnyObject", "Never", "Self", "Error", "CodingKey",
        // Common protocols
        "Codable", "Encodable", "Decodable", "Hashable", "Equatable",
        "Comparable", "Identifiable", "Sendable", "CustomStringConvertible",
        "RawRepresentable", "CaseIterable",
        // Foundation
        "Date", "URL", "Data", "UUID", "TimeInterval", "Locale",
        "DateFormatter", "JSONEncoder", "JSONDecoder",
        "NSObject", "NSCoding",
        // Core Graphics
        "CGFloat", "CGSize", "CGPoint", "CGRect",
        // SwiftUI views & modifiers
        "View", "Scene", "App", "Body",
        "Color", "Font", "Image", "Text", "Spacer", "Divider",
        "EmptyView", "AnyView", "TupleView",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack",
        "LazyVGrid", "LazyHGrid", "GridItem",
        "ScrollView", "List", "Form", "TabView", "NavigationStack",
        "NavigationLink", "NavigationPath", "NavigationSplitView",
        "Button", "Toggle", "Slider", "Picker", "TextField", "TextEditor",
        "ForEach", "Group", "Section",
        "Binding", "State", "StateObject", "ObservedObject", "EnvironmentObject",
        "Published", "ObservableObject", "Observable",
        "Alignment", "Edge", "EdgeInsets", "UnitPoint",
        "Animation", "Transition", "AnyTransition",
        "GeometryReader", "GeometryProxy",
        "PreferenceKey", "EnvironmentKey", "EnvironmentValues",
        "FocusState", "FocusedValue", "ScenePhase",
        "ViewModifier", "Shape", "Path", "RoundedRectangle", "Circle", "Rectangle",
        // Combine
        "AnyCancellable", "PassthroughSubject", "CurrentValueSubject",
        "AnyPublisher", "Publisher", "Subscriber",
        // Concurrency
        "Task", "TaskGroup", "AsyncStream", "AsyncSequence",
        "MainActor", "GlobalActor",
        // SwiftData / CoreData
        "ModelContext", "ModelContainer", "FetchDescriptor",
        "NSManagedObject", "NSManagedObjectContext",
    ]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Context tracking

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { contextStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { contextStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { contextStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { contextStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { contextStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { contextStack.removeLast() }

    // MARK: - Type annotation references

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        recordIfType(node.name.text, node: Syntax(node))
        return .visitChildren
    }

    // MARK: - Expression-level type references

    /// Detect initializer calls: `HeroSection(items: items)`, `MovieRecord(...)`.
    /// The callee of a FunctionCallExprSyntax is a DeclReferenceExprSyntax with an
    /// uppercase name when it's a type initializer.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            recordIfType(ref.baseName.text, node: Syntax(node))
        }
        return .visitChildren
    }

    /// Detect static member access: `Spacing.medium`, `DatabaseManager.openDatabase()`,
    /// `AppDestination.movieDetail`. The base of a MemberAccessExprSyntax is a
    /// DeclReferenceExprSyntax with an uppercase name when it's a type.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base?.as(DeclReferenceExprSyntax.self) {
            recordIfType(base.baseName.text, node: Syntax(node))
        }
        return .visitChildren
    }

    // MARK: - Helpers

    private func recordIfType(_ name: String, node: Syntax) {
        guard let context = contextStack.last,
              !Self.builtinTypes.contains(name),
              name != context,
              name.first?.isUppercase == true
        else { return }

        let location = node.startLocation(converter: converter)
        typeReferences.append(ExtractedTypeReference(
            containingSymbol: context,
            referencedTypeName: name,
            line: location.line
        ))
    }
}
