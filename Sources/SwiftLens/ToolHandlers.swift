import MCP
import SwiftLensCore
import Foundation

/// Dispatches MCP tool calls to the appropriate QueryEngine methods.
struct ToolHandlers: Sendable {
    let queryEngine: QueryEngine
    let indexingCoordinator: IndexingCoordinator
    let projectId: Int64
    let projectRoot: String
    let projectConfig: ProjectConfig

    func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]

        switch params.name {
        case "search_symbol":
            return try handleSearchSymbol(args)
        case "get_symbol":
            return try handleGetSymbol(args)
        case "find_conformers":
            return try handleFindConformers(args)
        case "get_module_graph":
            return try handleGetModuleGraph()
        case "trace_view_tree":
            return try handleTraceViewTree(args)
        case "get_architecture":
            return try handleGetArchitecture()
        case "list_extensions":
            return try handleListExtensions(args)
        case "find_dependencies":
            return try handleFindDependencies(args)
        case "reindex":
            return try await handleReindex()
        default:
            return CallTool.Result(
                content: [.text("Unknown tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Individual Handlers

    private func handleSearchSymbol(_ args: [String: Value]) throws -> CallTool.Result {
        guard let query = args["query"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: query")], isError: true)
        }

        let kind = args["kind"]?.stringValue.flatMap { NodeKind(rawValue: $0) }
        let module = args["module"]?.stringValue
        let limit = args["limit"]?.intValue ?? 20

        let results = try queryEngine.searchSymbol(
            projectId: projectId,
            query: query,
            kind: kind,
            module: module,
            limit: limit
        )

        if results.isEmpty {
            return CallTool.Result(content: [.text("No symbols found matching '\(query)'")])
        }

        var output = "Found \(results.count) symbol(s):\n\n"
        for r in results {
            output += "  \(r.kind) \(r.qualifiedName)"
            if let mod = r.moduleName { output += " [\(mod)]" }
            if let path = r.filePath, let line = r.line {
                let shortPath = shortenPath(path)
                output += " — \(shortPath):\(line)"
            }
            if let access = r.accessLevel { output += " (\(access))" }
            if let sig = r.signature { output += " \(sig)" }
            output += "\n"
        }
        return CallTool.Result(content: [.text(output)])
    }

    private func handleGetSymbol(_ args: [String: Value]) throws -> CallTool.Result {
        guard let name = args["name"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: name")], isError: true)
        }

        // Try qualified name first, then simple name search
        var detail = try queryEngine.getSymbol(projectId: projectId, qualifiedName: name)
        if detail == nil {
            // Try finding by simple name
            let searchResults = try queryEngine.searchSymbol(projectId: projectId, query: name, limit: 1)
            if let first = searchResults.first {
                detail = try queryEngine.getSymbol(projectId: projectId, symbolId: first.id)
            }
        }

        guard let detail else {
            return CallTool.Result(content: [.text("Symbol '\(name)' not found")])
        }

        var output = formatSymbolDetail(detail)
        return CallTool.Result(content: [.text(output)])
    }

    private func handleFindConformers(_ args: [String: Value]) throws -> CallTool.Result {
        guard let protocolName = args["protocol"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: protocol")], isError: true)
        }

        let results = try queryEngine.findConformers(projectId: projectId, protocolName: protocolName)

        if results.isEmpty {
            return CallTool.Result(content: [.text("No conformers found for protocol '\(protocolName)'")])
        }

        var output = "Types conforming to \(protocolName) (\(results.count)):\n\n"
        for r in results {
            output += "  \(r.kind) \(r.name)"
            if let mod = r.moduleName { output += " [\(mod)]" }
            if let path = r.filePath, let line = r.line {
                output += " — \(shortenPath(path)):\(line)"
            }
            output += "\n"
        }
        return CallTool.Result(content: [.text(output)])
    }

    private func handleGetModuleGraph() throws -> CallTool.Result {
        let graph = try queryEngine.getModuleGraph(projectId: projectId)

        var output = "Module Graph (\(graph.modules.count) modules):\n\n"
        for mod in graph.modules {
            output += "  \(mod.kind) \(mod.name)"
            if !mod.dependencies.isEmpty {
                output += " → [\(mod.dependencies.joined(separator: ", "))]"
            }
            output += "\n"
        }
        return CallTool.Result(content: [.text(output)])
    }

    private func handleTraceViewTree(_ args: [String: Value]) throws -> CallTool.Result {
        guard let rootView = args["root_view"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: root_view")], isError: true)
        }

        let maxDepth = args["max_depth"]?.intValue ?? 10
        let tree = try queryEngine.traceViewTree(projectId: projectId, rootView: rootView, maxDepth: maxDepth)

        var output = "View Tree for \(rootView):\n\n"
        output += formatViewTree(tree, indent: 0)
        return CallTool.Result(content: [.text(output)])
    }

    private func handleGetArchitecture() throws -> CallTool.Result {
        let arch = try queryEngine.getArchitecture(projectId: projectId)

        var output = "# Architecture Overview\n\n"

        output += "## Stats\n"
        output += "  Files: \(arch.fileCount) | Symbols: \(arch.totalSymbols) | Protocols: \(arch.protocolCount)\n\n"

        output += "## Modules (\(arch.modules.count))\n"
        for mod in arch.modules {
            output += "  \(mod.kind) \(mod.name)\n"
        }

        if !arch.protocolStats.isEmpty {
            output += "\n## Key Protocols\n"
            for proto in arch.protocolStats {
                output += "  \(proto.name) — \(proto.conformerCount) conformer(s)\n"
            }
        }

        if !arch.viewModels.isEmpty {
            output += "\n## View Models\n"
            for vm in arch.viewModels {
                output += "  \(vm.name)"
                if let path = vm.filePath, let line = vm.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
        }

        if !arch.environmentKeys.isEmpty {
            output += "\n## Environment Keys\n"
            for key in arch.environmentKeys {
                output += "  \(key.keyName)"
                if let type = key.valueType { output += ": \(type)" }
                output += "\n"
            }
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleListExtensions(_ args: [String: Value]) throws -> CallTool.Result {
        guard let typeName = args["type_name"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: type_name")], isError: true)
        }

        let extensions = try queryEngine.listExtensions(projectId: projectId, typeName: typeName)

        if extensions.isEmpty {
            return CallTool.Result(content: [.text("No extensions found for '\(typeName)'")])
        }

        var output = "Extensions of \(typeName) (\(extensions.count)):\n\n"
        for (i, ext) in extensions.enumerated() {
            output += "  Extension #\(i + 1)"
            if let path = ext.filePath, let line = ext.line {
                output += " — \(shortenPath(path)):\(line)"
            }
            output += "\n"
            if !ext.conformances.isEmpty {
                output += "    Conformances: \(ext.conformances.joined(separator: ", "))\n"
            }
            for member in ext.members {
                output += "    \(member)\n"
            }
        }
        return CallTool.Result(content: [.text(output)])
    }

    private func handleFindDependencies(_ args: [String: Value]) throws -> CallTool.Result {
        guard let symbol = args["symbol"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: symbol")], isError: true)
        }

        let directionStr = args["direction"]?.stringValue ?? "both"
        let direction: DependencyDirection = switch directionStr {
        case "incoming": .incoming
        case "outgoing": .outgoing
        default: .both
        }

        let result = try queryEngine.findDependencies(
            projectId: projectId,
            symbolName: symbol,
            direction: direction
        )

        var output = "Dependencies of \(symbol):\n\n"

        if !result.dependsOn.isEmpty {
            output += "  Depends on (\(result.dependsOn.count)):\n"
            for dep in result.dependsOn {
                output += "    → \(dep.kind) \(dep.name) [\(dep.relationship)]"
                if let path = dep.filePath, let line = dep.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
        }

        if !result.dependedOnBy.isEmpty {
            output += "  Depended on by (\(result.dependedOnBy.count)):\n"
            for dep in result.dependedOnBy {
                output += "    ← \(dep.kind) \(dep.name) [\(dep.relationship)]"
                if let path = dep.filePath, let line = dep.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
        }

        if result.dependsOn.isEmpty && result.dependedOnBy.isEmpty {
            output += "  No dependencies found.\n"
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleReindex() async throws -> CallTool.Result {
        let result = try await indexingCoordinator.index(
            projectRoot: projectRoot,
            config: projectConfig
        )

        let output = """
            Reindex complete:
              Total files: \(result.totalFiles)
              Files indexed: \(result.indexedFiles)
              Files deleted: \(result.deletedFiles)
              Modules: \(result.modules)
            """
        return CallTool.Result(content: [.text(output)])
    }

    // MARK: - Formatting Helpers

    private func shortenPath(_ path: String) -> String {
        if path.hasPrefix(projectRoot) {
            return String(path.dropFirst(projectRoot.count + 1))
        }
        return path
    }

    private func formatSymbolDetail(_ detail: SymbolDetail) -> String {
        let s = detail.symbol
        var output = "\(s.kind) \(s.qualifiedName)"
        if let mod = detail.moduleName { output += " [\(mod)]" }
        output += "\n"

        if let path = s.filePath, let line = s.line {
            output += "  Location: \(shortenPath(path)):\(line)"
            if let endLine = s.endLine { output += "-\(endLine)" }
            output += "\n"
        }
        if let access = s.accessLevel { output += "  Access: \(access)\n" }
        if let sig = s.signature { output += "  Signature: \(sig)\n" }
        if let doc = s.documentation { output += "  Doc: \(doc)\n" }

        if let attrs = s.attributes, let arr = try? JSONDecoder().decode([String].self, from: Data(attrs.utf8)), !arr.isEmpty {
            output += "  Attributes: \(arr.joined(separator: ", "))\n"
        }

        if !detail.conformances.isEmpty {
            output += "  Conformances:\n"
            for c in detail.conformances {
                output += "    \(c.relationship): \(c.name)\n"
            }
        }

        if !detail.members.isEmpty {
            output += "  Members (\(detail.members.count)):\n"
            for m in detail.members {
                output += "    \(m.kind) \(m.name)"
                if let sig = m.signature { output += ": \(sig)" }
                if let access = m.accessLevel { output += " (\(access))" }
                output += "\n"
            }
        }

        if !detail.extensions.isEmpty {
            output += "  Extensions (\(detail.extensions.count)):\n"
            for ext in detail.extensions {
                output += "    extension at \(ext.name)"
                if let line = ext.line { output += ":\(line)" }
                output += "\n"
            }
        }

        if !detail.wrapperUsages.isEmpty {
            output += "  Wrappers:\n"
            for w in detail.wrapperUsages {
                output += "    @\(w.wrapperName)"
                if let arg = w.argument { output += "(\(arg))" }
                output += "\n"
            }
        }

        return output
    }

    private func formatViewTree(_ node: ViewTreeNode, indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)
        var output = "\(prefix)\(node.name)"
        if let path = node.filePath, let line = node.line {
            output += " — \(shortenPath(path)):\(line)"
        }
        output += "\n"
        for child in node.children {
            output += formatViewTree(child, indent: indent + 1)
        }
        return output
    }
}
