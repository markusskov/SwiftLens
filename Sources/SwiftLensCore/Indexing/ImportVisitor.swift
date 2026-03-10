import SwiftSyntax

/// Extracts import statements from Swift source.
final class ImportVisitor: SyntaxVisitor {
    var imports: [ExtractedImport] = []

    private let converter: SourceLocationConverter

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let moduleName = node.path.map(\.name.text).joined(separator: ".")
        let location = node.startLocation(converter: converter)

        let isTestable = node.attributes.contains { element in
            guard case .attribute(let attr) = element else { return false }
            return attr.attributeName.trimmedDescription == "testable"
        }

        imports.append(ExtractedImport(
            moduleName: moduleName,
            isTestable: isTestable,
            line: location.line
        ))

        return .skipChildren
    }
}
