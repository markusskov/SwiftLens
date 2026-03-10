import SwiftSyntax

/// Extracts property wrapper usage (@State, @Environment, @Observable, etc.).
final class PropertyWrapperVisitor: SyntaxVisitor {
    var wrapperUsages: [ExtractedWrapperUsage] = []
    var environmentUsages: [ExtractedEnvironmentUsage] = []
    var environmentDeclarations: [ExtractedEnvironmentDeclaration] = []

    private let converter: SourceLocationConverter

    /// Stack of current type names for context.
    private var typeStack: [String] = []

    private let trackedWrappers: Set<String> = [
        "State", "Binding", "Environment", "EnvironmentObject",
        "Observable", "ObservedObject", "StateObject",
        "Published", "AppStorage", "SceneStorage",
        "FocusState", "FocusedValue", "Query", "Entry",
        "MainActor",
    ]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Type tracking

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)

        if let inheritance = node.inheritanceClause {
            let types = inheritance.inheritedTypes.map { $0.type.trimmedDescription }
            if types.contains("EnvironmentKey") {
                extractEnvironmentKeyDeclaration(from: node, typeName: node.name.text)
            }
        }

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
        let typeName = node.extendedType.trimmedDescription

        if let inheritance = node.inheritanceClause {
            let types = inheritance.inheritedTypes.map { $0.type.trimmedDescription }
            if types.contains("EnvironmentKey") {
                extractEnvironmentKeyFromExtension(node, typeName: typeName)
            }
        }

        if typeName == "EnvironmentValues" {
            extractEnvironmentValueProperties(from: node)
        }

        typeStack.append(typeName)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    // MARK: - Variable declarations with wrappers

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: converter)

        for attribute in node.attributes {
            guard case .attribute(let attr) = attribute else { continue }

            let attrName = attr.attributeName.trimmedDescription
            guard trackedWrappers.contains(attrName) else { continue }

            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    continue
                }

                var argument: String?
                if let args = attr.arguments,
                   case .argumentList(let argList) = args {
                    argument = argList.first?.expression.trimmedDescription
                }

                wrapperUsages.append(ExtractedWrapperUsage(
                    wrapperName: attrName,
                    argument: argument,
                    propertyName: name,
                    line: location.line
                ))

                if attrName == "Environment", let arg = argument, let viewName = typeStack.last {
                    environmentUsages.append(ExtractedEnvironmentUsage(
                        viewName: viewName,
                        keyPath: arg,
                        propertyName: name,
                        line: location.line
                    ))
                }
            }
        }

        return .skipChildren
    }

    // MARK: - EnvironmentKey Extraction

    private func extractEnvironmentKeyDeclaration(
        from node: StructDeclSyntax,
        typeName: String
    ) {
        let location = node.startLocation(converter: converter)
        for member in node.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                       name == "defaultValue" {
                        let valueType = binding.typeAnnotation?.type.trimmedDescription
                        environmentDeclarations.append(ExtractedEnvironmentDeclaration(
                            keyName: typeName,
                            valueType: valueType,
                            typeName: typeName,
                            line: location.line
                        ))
                    }
                }
            }
        }
    }

    private func extractEnvironmentKeyFromExtension(
        _ node: ExtensionDeclSyntax,
        typeName: String
    ) {
        let location = node.startLocation(converter: converter)
        for member in node.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                       name == "defaultValue" {
                        let valueType = binding.typeAnnotation?.type.trimmedDescription
                        environmentDeclarations.append(ExtractedEnvironmentDeclaration(
                            keyName: typeName,
                            valueType: valueType,
                            typeName: typeName,
                            line: location.line
                        ))
                    }
                }
            }
        }
    }

    private func extractEnvironmentValueProperties(from node: ExtensionDeclSyntax) {
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let location = varDecl.startLocation(converter: converter)

            for binding in varDecl.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    continue
                }
                let valueType = binding.typeAnnotation?.type.trimmedDescription

                environmentDeclarations.append(ExtractedEnvironmentDeclaration(
                    keyName: name,
                    valueType: valueType,
                    typeName: "EnvironmentValues",
                    line: location.line
                ))
            }
        }
    }
}
