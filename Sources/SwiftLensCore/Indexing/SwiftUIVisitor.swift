import SwiftSyntax

/// Extracts SwiftUI view composition relationships from `body` properties.
final class SwiftUIVisitor: SyntaxVisitor {
    var viewCompositions: [ExtractedViewComposition] = []

    private let converter: SourceLocationConverter

    /// Stack of current type names.
    private var typeStack: [String] = []

    /// Whether we're inside a `body` computed property.
    private var insideBody = false

    /// Known non-view identifiers to skip.
    private static let viewDenyList: Set<String> = [
        "Color", "Font", "Image", "Text", "Spacer", "Divider",
        "CGFloat", "CGSize", "CGPoint", "CGRect",
        "String", "Int", "Double", "Bool", "Date", "URL",
        "Array", "Dictionary", "Set", "Optional",
        "AnyView", "EmptyView", "TupleView",
        "ForEach", "Group", "Section",
        "EdgeInsets", "Alignment", "HorizontalAlignment", "VerticalAlignment",
        "Animation", "Transition",
        "some", "Self", "Never",
    ]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Type tracking

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    // MARK: - Body detection

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
               name == "body",
               binding.accessorBlock != nil {
                insideBody = true
                return .visitChildren
            }
        }
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
               name == "body" {
                insideBody = false
            }
        }
    }

    // MARK: - View composition detection

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard insideBody, let parentView = typeStack.last else {
            return .visitChildren
        }

        let callee = node.calledExpression

        // Direct view reference: `SomeView(...)`
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if isLikelyView(name) {
                let location = node.startLocation(converter: converter)
                viewCompositions.append(ExtractedViewComposition(
                    parentView: parentView,
                    childView: name,
                    line: location.line
                ))
            }
        }

        // Member access: `Module.SomeView(...)` — take the last component
        if let member = callee.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if isLikelyView(name) {
                let location = node.startLocation(converter: converter)
                viewCompositions.append(ExtractedViewComposition(
                    parentView: parentView,
                    childView: name,
                    line: location.line
                ))
            }
        }

        return .visitChildren
    }

    // MARK: - Navigation destination detection

    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        if node.label?.text == "for",
           let memberAccess = node.expression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "self" {
            if let base = memberAccess.base?.as(DeclReferenceExprSyntax.self) {
                let typeName = base.baseName.text
                if let parentView = typeStack.last {
                    let location = node.startLocation(converter: converter)
                    viewCompositions.append(ExtractedViewComposition(
                        parentView: parentView,
                        childView: "NavigationDestination(\(typeName))",
                        line: location.line
                    ))
                }
            }
        }
        return .visitChildren
    }

    // MARK: - Helpers

    private func isLikelyView(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase else { return false }
        guard !Self.viewDenyList.contains(name) else { return false }
        guard name != typeStack.last else { return false }
        return true
    }
}
