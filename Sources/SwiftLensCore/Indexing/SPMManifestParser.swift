import SwiftParser
import SwiftSyntax
import Foundation

/// Parsed representation of an SPM target.
public struct SPMTarget: Sendable, Equatable {
    public let name: String
    public let kind: SPMTargetKind
    public let path: String?
    public let dependencies: [String]

    public init(name: String, kind: SPMTargetKind, path: String?, dependencies: [String]) {
        self.name = name
        self.kind = kind
        self.path = path
        self.dependencies = dependencies
    }
}

public enum SPMTargetKind: String, Sendable, Equatable {
    case regular
    case executable
    case test
    case plugin
    case system
    case binary
    case macro
}

/// Parses Package.swift files using swift-syntax to extract target names and dependencies.
public struct SPMManifestParser: Sendable {

    public init() {}

    /// Parse a Package.swift file and return all targets.
    public func parse(manifestPath: String) throws -> [SPMTarget] {
        let source = try String(contentsOfFile: manifestPath, encoding: .utf8)
        return parse(source: source)
    }

    /// Parse Package.swift source code and return all targets.
    public func parse(source: String) -> [SPMTarget] {
        let sourceFile = Parser.parse(source: source)
        let visitor = PackageVisitor(viewMode: .sourceAccurate)
        visitor.walk(sourceFile)
        return visitor.targets
    }
}

// MARK: - Syntax Visitor

private final class PackageVisitor: SyntaxVisitor {
    var targets: [SPMTarget] = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Look for .target(...), .executableTarget(...), .testTarget(...), etc.
        let callee = node.calledExpression.trimmedDescription

        let targetKinds: [String: SPMTargetKind] = [
            ".target": .regular,
            ".executableTarget": .executable,
            ".testTarget": .test,
            ".plugin": .plugin,
            ".systemLibrary": .system,
            ".binaryTarget": .binary,
            ".macro": .macro,
        ]

        guard let kind = targetKinds[callee] else {
            return .visitChildren
        }

        var name: String?
        var path: String?
        var deps: [String] = []

        for arg in node.arguments {
            let label = arg.label?.text
            let expr = arg.expression

            switch label {
            case "name":
                name = extractStringLiteral(expr)
            case "path":
                path = extractStringLiteral(expr)
            case "dependencies":
                deps = extractDependencyNames(expr)
            default:
                break
            }
        }

        if let name {
            targets.append(SPMTarget(
                name: name,
                kind: kind,
                path: path,
                dependencies: deps
            ))
        }

        // Skip children to avoid picking up .target(name:) in dependency arrays
        return .skipChildren
    }

    /// Extract a string literal value from an expression.
    private func extractStringLiteral(_ expr: ExprSyntax) -> String? {
        if let literal = expr.as(StringLiteralExprSyntax.self) {
            return literal.segments.trimmedDescription
        }
        return nil
    }

    /// Extract dependency names from an array expression.
    /// Handles: "DepName", .target(name: "X"), .product(name: "X", package: "Y"),
    /// .byName(name: "X"), bare DepName references
    private func extractDependencyNames(_ expr: ExprSyntax) -> [String] {
        guard let array = expr.as(ArrayExprSyntax.self) else { return [] }

        var names: [String] = []
        for element in array.elements {
            let elementExpr = element.expression

            // String literal: "DepName"
            if let name = extractStringLiteral(elementExpr) {
                names.append(name)
                continue
            }

            // Function call: .target(name: "X"), .product(name: "X", package: "Y")
            if let call = elementExpr.as(FunctionCallExprSyntax.self) {
                for arg in call.arguments {
                    if arg.label?.text == "name",
                       let name = extractStringLiteral(arg.expression) {
                        names.append(name)
                        break
                    }
                }
                continue
            }

            // Bare reference: DeclReferenceExprSyntax
            if let ref = elementExpr.as(DeclReferenceExprSyntax.self) {
                names.append(ref.baseName.text)
            }
        }

        return names
    }
}
