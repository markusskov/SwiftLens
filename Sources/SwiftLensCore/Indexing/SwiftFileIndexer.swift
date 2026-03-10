import SwiftParser
import SwiftSyntax
import Foundation

/// Parses a single Swift file and runs all extraction visitors in one pass.
public struct SwiftFileIndexer: Sendable {

    public init() {}

    /// Parse and extract all information from a Swift source file.
    public func index(filePath: String) throws -> FileExtractionResult {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        return index(source: source, filePath: filePath)
    }

    /// Parse and extract from in-memory source (for testing).
    public func index(source: String, filePath: String) -> FileExtractionResult {
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: filePath, tree: sourceFile)

        let declVisitor = DeclarationVisitor(converter: converter)
        let importVisitor = ImportVisitor(converter: converter)
        let wrapperVisitor = PropertyWrapperVisitor(converter: converter)
        let swiftUIVisitor = SwiftUIVisitor(converter: converter)

        declVisitor.walk(sourceFile)
        importVisitor.walk(sourceFile)
        wrapperVisitor.walk(sourceFile)
        swiftUIVisitor.walk(sourceFile)

        var result = FileExtractionResult(filePath: filePath)
        result.declarations = declVisitor.declarations
        result.imports = importVisitor.imports
        result.wrapperUsages = wrapperVisitor.wrapperUsages
        result.viewCompositions = swiftUIVisitor.viewCompositions
        result.environmentUsages = wrapperVisitor.environmentUsages
        result.environmentDeclarations = wrapperVisitor.environmentDeclarations

        return result
    }
}
