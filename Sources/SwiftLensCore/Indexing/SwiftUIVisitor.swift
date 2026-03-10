import SwiftSyntax

/// Extracts SwiftUI view composition relationships from `body` properties.
final class SwiftUIVisitor: SyntaxVisitor {
    var viewCompositions: [ExtractedViewComposition] = []
    var environmentInjections: [ExtractedEnvironmentInjection] = []

    private let converter: SourceLocationConverter

    /// Stack of current type names.
    private var typeStack: [String] = []

    /// Whether we're inside a view builder context (body, @ViewBuilder, or View-returning property).
    private var insideViewBuilder = false

    /// Stack of conditional contexts (if/else, switch/case, ForEach).
    private var contextStack: [String] = []

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

    /// Suffixes indicating non-View types to reduce false positives.
    private static let nonViewSuffixes: [String] = [
        "ViewModel", "Model", "Manager", "Service", "Repository",
        "Store", "Controller", "Coordinator", "Provider", "Factory",
        "Handler", "Delegate", "DataSource", "Helper",
        "Formatter", "Router", "Interactor", "Presenter", "UseCase",
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

    // MARK: - View builder context detection

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard binding.accessorBlock != nil else { continue }
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                if name == "body"
                    || isViewReturning(binding: binding)
                    || hasViewBuilderAttribute(node.attributes) {
                    insideViewBuilder = true
                    return .visitChildren
                }
            }
        }
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard binding.accessorBlock != nil else { continue }
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                if name == "body"
                    || isViewReturning(binding: binding)
                    || hasViewBuilderAttribute(node.attributes) {
                    insideViewBuilder = false
                }
            }
        }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasViewBuilderAttribute(node.attributes) || isViewReturningFunction(node) {
            insideViewBuilder = true
        }
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        if hasViewBuilderAttribute(node.attributes) || isViewReturningFunction(node) {
            insideViewBuilder = false
        }
    }

    // MARK: - Conditional context tracking

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        guard insideViewBuilder else { return .visitChildren }
        let condition = node.conditions.trimmedDescription
        let label = condition.count > 40
            ? "if " + condition.prefix(37) + "..."
            : "if " + condition
        contextStack.append(label)
        return .visitChildren
    }

    override func visitPost(_ node: IfExprSyntax) {
        guard insideViewBuilder else { return }
        contextStack.removeLast()
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        guard insideViewBuilder else { return .visitChildren }
        if let caseLabel = node.label.as(SwitchCaseLabelSyntax.self) {
            let items = caseLabel.caseItems.map { $0.pattern.trimmedDescription }.joined(separator: ", ")
            let label = items.count > 40
                ? "case " + items.prefix(35) + "..."
                : "case " + items
            contextStack.append(label)
        } else {
            contextStack.append("default")
        }
        return .visitChildren
    }

    override func visitPost(_ node: SwitchCaseSyntax) {
        guard insideViewBuilder else { return }
        contextStack.removeLast()
    }

    // MARK: - View composition & environment injection detection

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression

        // Detect .environment() / .environmentObject() modifier injections.
        // These can appear anywhere — in body, helper properties, scene builders —
        // so we only require being inside a type, not inside body specifically.
        if let parentView = typeStack.last,
           let member = callee.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if name == "environment" || name == "environmentObject" {
                if let firstArg = node.arguments.first {
                    let keyPath = firstArg.expression.trimmedDescription
                    let location = node.startLocation(converter: converter)
                    environmentInjections.append(ExtractedEnvironmentInjection(
                        viewName: parentView,
                        keyPath: keyPath,
                        line: location.line
                    ))
                }
            }
        }

        // Track ForEach as a conditional context
        if insideViewBuilder {
            if let ref = callee.as(DeclReferenceExprSyntax.self), ref.baseName.text == "ForEach" {
                contextStack.append("ForEach")
            }
        }

        // View composition detection requires being inside a view builder context.
        guard insideViewBuilder, let parentView = typeStack.last else {
            return .visitChildren
        }

        let currentContext = contextStack.isEmpty ? nil : contextStack.joined(separator: " > ")

        // Direct view reference: `SomeView(...)`
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if isLikelyView(name) {
                let location = node.startLocation(converter: converter)
                viewCompositions.append(ExtractedViewComposition(
                    parentView: parentView,
                    childView: name,
                    line: location.line,
                    context: currentContext
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
                    line: location.line,
                    context: currentContext
                ))
            }
        }

        return .visitChildren
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        guard insideViewBuilder else { return }
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "ForEach" {
            contextStack.removeLast()
        }
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

    private func isViewReturning(binding: PatternBindingSyntax) -> Bool {
        guard let typeDesc = binding.typeAnnotation?.type.trimmedDescription else { return false }
        return typeDesc.contains("View")
    }

    private func isViewReturningFunction(_ node: FunctionDeclSyntax) -> Bool {
        guard let returnType = node.signature.returnClause?.type.trimmedDescription else { return false }
        return returnType.contains("View")
    }

    private func hasViewBuilderAttribute(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { attr in
            attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "ViewBuilder"
        }
    }

    private func isLikelyView(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase else { return false }
        guard !Self.viewDenyList.contains(name) else { return false }
        guard name != typeStack.last else { return false }
        for suffix in Self.nonViewSuffixes {
            if name.hasSuffix(suffix) { return false }
        }
        return true
    }
}
