import SwiftSyntax

/// Extracts all declarations (types, functions, properties, etc.) from Swift syntax.
final class DeclarationVisitor: SyntaxVisitor {
    var declarations: [ExtractedDeclaration] = []

    private let converter: SourceLocationConverter

    /// Stack of parent type names for building qualified names.
    private var parentStack: [String] = []

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Types

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let decl = extractTypeDeclaration(
            kind: .struct, name: node.name.text,
            inheritanceClause: node.inheritanceClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            node: Syntax(node),
            leadingTrivia: node.leadingTrivia
        )
        appendDeclaration(decl)
        parentStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let decl = extractTypeDeclaration(
            kind: .class, name: node.name.text,
            inheritanceClause: node.inheritanceClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            node: Syntax(node),
            leadingTrivia: node.leadingTrivia
        )
        appendDeclaration(decl)
        parentStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let decl = extractTypeDeclaration(
            kind: .enum, name: node.name.text,
            inheritanceClause: node.inheritanceClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            node: Syntax(node),
            leadingTrivia: node.leadingTrivia
        )
        appendDeclaration(decl)
        parentStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let decl = extractTypeDeclaration(
            kind: .protocol, name: node.name.text,
            inheritanceClause: node.inheritanceClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            node: Syntax(node),
            leadingTrivia: node.leadingTrivia
        )
        appendDeclaration(decl)
        parentStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let decl = extractTypeDeclaration(
            kind: .actor, name: node.name.text,
            inheritanceClause: node.inheritanceClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            node: Syntax(node),
            leadingTrivia: node.leadingTrivia
        )
        appendDeclaration(decl)
        parentStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.extendedType.trimmedDescription
        let location = node.startLocation(converter: converter)
        let endLocation = node.endLocation(converter: converter)

        let decl = ExtractedDeclaration(
            kind: .extension,
            name: typeName,
            line: location.line,
            column: location.column,
            endLine: endLocation.line,
            accessLevel: extractAccessLevel(node.modifiers),
            attributes: extractAttributes(node.attributes),
            modifiers: extractModifiers(node.modifiers),
            inheritedTypes: extractInheritedTypes(node.inheritanceClause),
            parent: currentParent
        )
        appendDeclaration(decl)
        parentStack.append(typeName)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        parentStack.removeLast()
    }

    // MARK: - Members

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: converter)
        let sig = buildFunctionSignature(node)

        let decl = ExtractedDeclaration(
            kind: .function,
            name: node.name.text,
            line: location.line,
            column: location.column,
            accessLevel: extractAccessLevel(node.modifiers),
            attributes: extractAttributes(node.attributes),
            modifiers: extractModifiers(node.modifiers),
            signature: sig,
            documentation: extractDocComment(node.leadingTrivia),
            parent: currentParent
        )
        appendDeclaration(decl)
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: converter)
        let attrs = extractAttributes(node.attributes)
        let mods = extractModifiers(node.modifiers)

        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                continue
            }

            let typeAnnotation = binding.typeAnnotation?.type.trimmedDescription
            let isComputed = binding.accessorBlock != nil

            var sig = typeAnnotation ?? ""
            if isComputed { sig += " { get }" }

            let decl = ExtractedDeclaration(
                kind: .variable,
                name: name,
                line: location.line,
                column: location.column,
                accessLevel: extractAccessLevel(node.modifiers),
                attributes: attrs,
                modifiers: mods,
                signature: sig.isEmpty ? nil : sig,
                documentation: extractDocComment(node.leadingTrivia),
                parent: currentParent
            )
            appendDeclaration(decl)
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: converter)
        let params = node.signature.parameterClause.parameters.map { param in
            let label = param.firstName.text
            let type = param.type.trimmedDescription
            if let secondName = param.secondName?.text {
                return "\(label) \(secondName): \(type)"
            }
            return "\(label): \(type)"
        }.joined(separator: ", ")

        let failable = node.optionalMark?.text ?? ""

        let decl = ExtractedDeclaration(
            kind: .initializer,
            name: "init\(failable)",
            line: location.line,
            column: location.column,
            accessLevel: extractAccessLevel(node.modifiers),
            attributes: extractAttributes(node.attributes),
            modifiers: extractModifiers(node.modifiers),
            signature: "(\(params))",
            documentation: extractDocComment(node.leadingTrivia),
            parent: currentParent
        )
        appendDeclaration(decl)
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: converter)
        let decl = ExtractedDeclaration(
            kind: .typeAlias,
            name: node.name.text,
            line: location.line,
            column: location.column,
            accessLevel: extractAccessLevel(node.modifiers),
            attributes: extractAttributes(node.attributes),
            modifiers: extractModifiers(node.modifiers),
            signature: node.initializer.value.trimmedDescription,
            documentation: extractDocComment(node.leadingTrivia),
            parent: currentParent
        )
        appendDeclaration(decl)
        return .skipChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: converter)
        for element in node.elements {
            let sig: String?
            if let params = element.parameterClause {
                sig = params.trimmedDescription
            } else if let rawValue = element.rawValue {
                sig = rawValue.value.trimmedDescription
            } else {
                sig = nil
            }

            let decl = ExtractedDeclaration(
                kind: .enumCase,
                name: element.name.text,
                line: location.line,
                column: location.column,
                accessLevel: nil,
                signature: sig,
                parent: currentParent
            )
            appendDeclaration(decl)
        }
        return .skipChildren
    }

    // MARK: - Helpers

    private var currentParent: String? {
        parentStack.last
    }

    private func appendDeclaration(_ decl: ExtractedDeclaration) {
        declarations.append(decl)
    }

    private func extractTypeDeclaration(
        kind: NodeKind, name: String,
        inheritanceClause: InheritanceClauseSyntax?,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        node: Syntax,
        leadingTrivia: Trivia?
    ) -> ExtractedDeclaration {
        let location = node.startLocation(converter: converter)
        let endLocation = node.endLocation(converter: converter)

        return ExtractedDeclaration(
            kind: kind,
            name: name,
            line: location.line,
            column: location.column,
            endLine: endLocation.line,
            accessLevel: extractAccessLevel(modifiers),
            attributes: extractAttributes(attributes),
            modifiers: extractModifiers(modifiers),
            inheritedTypes: extractInheritedTypes(inheritanceClause),
            documentation: extractDocComment(leadingTrivia),
            parent: currentParent
        )
    }

    private func extractAccessLevel(_ modifiers: DeclModifierListSyntax) -> String? {
        let accessLevels: Set<String> = ["public", "private", "fileprivate", "internal", "package", "open"]
        for modifier in modifiers {
            let name = modifier.name.text
            if accessLevels.contains(name) {
                return name
            }
        }
        return nil
    }

    private func extractAttributes(_ attributes: AttributeListSyntax) -> [String] {
        attributes.compactMap { element in
            guard case .attribute(let attr) = element else { return nil }
            return "@\(attr.attributeName.trimmedDescription)"
        }
    }

    private func extractModifiers(_ modifiers: DeclModifierListSyntax) -> [String] {
        let accessLevels: Set<String> = ["public", "private", "fileprivate", "internal", "package", "open"]
        return modifiers.compactMap { modifier in
            let name = modifier.name.text
            guard !accessLevels.contains(name) else { return nil }
            return name
        }
    }

    private func extractInheritedTypes(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { $0.type.trimmedDescription }
    }

    private func buildFunctionSignature(_ node: FunctionDeclSyntax) -> String {
        let params = node.signature.parameterClause.parameters.map { param in
            let label = param.firstName.text
            let type = param.type.trimmedDescription
            if let secondName = param.secondName?.text {
                return "\(label) \(secondName): \(type)"
            }
            return "\(label): \(type)"
        }.joined(separator: ", ")

        var sig = "(\(params))"

        if let returnClause = node.signature.returnClause {
            sig += " -> \(returnClause.type.trimmedDescription)"
        }

        if node.signature.effectSpecifiers?.asyncSpecifier != nil {
            sig = "async \(sig)"
        }
        if node.signature.effectSpecifiers?.throwsClause != nil {
            sig = "throws \(sig)"
        }

        return sig
    }

    private func extractDocComment(_ trivia: Trivia?) -> String? {
        guard let trivia else { return nil }
        var lines: [String] = []
        for piece in trivia {
            switch piece {
            case .docLineComment(let text):
                lines.append(String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            case .docBlockComment(let text):
                let trimmed = text.dropFirst(3).dropLast(2)
                lines.append(String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                break
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
