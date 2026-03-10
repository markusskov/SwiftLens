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
        case "find_dead_code":
            return try handleFindDeadCode(args)
        case "check_protocol_coverage":
            return try handleCheckProtocolCoverage(args)
        case "impact_analysis":
            return try handleImpactAnalysis(args)
        case "check_environment_injection":
            return try handleCheckEnvironmentInjection()
        case "audit_access_control":
            return try handleAuditAccessControl(args)
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

        let output = formatSymbolDetail(detail)
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

    private func handleFindDeadCode(_ args: [String: Value]) throws -> CallTool.Result {
        let module = args["module"]?.stringValue

        let results = try queryEngine.findDeadCode(projectId: projectId, module: module)

        if results.isEmpty {
            return CallTool.Result(content: [.text("No dead code found — all symbols have incoming references.")])
        }

        var output = "Potentially dead code (\(results.count) symbols):\n\n"
        for entry in results {
            output += "  \(entry.kind) \(entry.name)"
            if let mod = entry.moduleName { output += " [\(mod)]" }
            if let path = entry.filePath, let line = entry.line {
                output += " — \(shortenPath(path)):\(line)"
            }
            output += "\n"
        }
        output += "\nNote: These symbols have no incoming structural edges (conformsTo, inherits, composesView, usesEnvironment). Symbols used only via runtime reflection or string-based lookup may be false positives."
        return CallTool.Result(content: [.text(output)])
    }

    private func handleCheckProtocolCoverage(_ args: [String: Value]) throws -> CallTool.Result {
        guard let protocolName = args["protocol"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: protocol")], isError: true)
        }

        let showSatisfied = args["show_satisfied"]?.boolValue ?? false

        let result = try queryEngine.checkProtocolCoverage(
            projectId: projectId,
            protocolName: protocolName,
            showSatisfied: showSatisfied
        )

        if result.requirements.isEmpty && result.conformers.isEmpty {
            return CallTool.Result(content: [.text("Protocol '\(protocolName)' not found or has no requirements.")])
        }

        var output = "Protocol \(protocolName) — \(result.requirements.count) requirement(s), \(result.conformers.count) conformer(s):\n\n"

        output += "Requirements:\n"
        for req in result.requirements {
            output += "  \(req.kind) \(req.name)"
            if let sig = req.signature { output += ": \(sig)" }
            output += "\n"
        }

        for conformer in result.conformers {
            output += "\n\(conformer.kind) \(conformer.name)"
            if let path = conformer.filePath, let line = conformer.line {
                output += " — \(shortenPath(path)):\(line)"
            }

            if conformer.missing.isEmpty {
                output += " — COMPLETE\n"
            } else {
                output += " — MISSING \(conformer.missing.count)\n"
            }

            if showSatisfied {
                for name in conformer.satisfied {
                    output += "  + \(name)\n"
                }
            }
            for name in conformer.missing {
                output += "  - \(name) (MISSING)\n"
            }
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleImpactAnalysis(_ args: [String: Value]) throws -> CallTool.Result {
        guard let symbol = args["symbol"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: symbol")], isError: true)
        }

        let maxDepth = args["max_depth"]?.intValue ?? 5
        let directionStr = args["direction"]?.stringValue ?? "incoming"
        let direction: DependencyDirection = switch directionStr {
        case "outgoing": .outgoing
        case "both": .both
        default: .incoming
        }

        if direction == .both {
            let incoming = try queryEngine.impactAnalysis(
                projectId: projectId, symbolName: symbol, direction: .incoming, maxDepth: maxDepth
            )
            let outgoing = try queryEngine.impactAnalysis(
                projectId: projectId, symbolName: symbol, direction: .outgoing, maxDepth: maxDepth
            )

            var output = "Impact Analysis for \(symbol):\n\n"
            output += "== Incoming (what depends on \(symbol)) ==\n"
            output += formatImpactTree(incoming, indent: 0)
            output += "\n== Outgoing (what \(symbol) depends on) ==\n"
            output += formatImpactTree(outgoing, indent: 0)
            return CallTool.Result(content: [.text(output)])
        }

        let tree = try queryEngine.impactAnalysis(
            projectId: projectId, symbolName: symbol, direction: direction, maxDepth: maxDepth
        )

        var output = "Impact Analysis for \(symbol) (\(directionStr)):\n\n"
        output += formatImpactTree(tree, indent: 0)

        let nodeCount = countImpactNodes(tree) - 1 // exclude root
        if nodeCount == 0 {
            output += "\nNo transitive dependencies found."
        } else {
            output += "\nTotal: \(nodeCount) symbol(s) in the dependency chain."
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleCheckEnvironmentInjection() throws -> CallTool.Result {
        let results = try queryEngine.checkEnvironmentInjection(projectId: projectId)

        if results.isEmpty {
            return CallTool.Result(content: [.text("No @Environment usages found.")])
        }

        let missing = results.filter { $0.status == .missing }
        let provided = results.filter { $0.status == .provided }

        var output = "Environment Injection Check (\(results.count) usages):\n\n"

        if !missing.isEmpty {
            output += "MISSING INJECTIONS (\(missing.count)) — potential runtime crashes:\n"
            for check in missing {
                output += "  ! \(check.viewName) reads @Environment(\(check.keyPath))"
                if let path = check.viewFile, let line = check.viewLine {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n    No ancestor provides \(check.keyName) via .environment() modifier\n"
            }
        }

        if !provided.isEmpty {
            output += "\nPROVIDED (\(provided.count)):\n"
            for check in provided {
                output += "  + \(check.viewName) reads \(check.keyName)"
                if let provider = check.injectedBy {
                    output += " — injected by \(provider)"
                }
                output += "\n"
            }
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleAuditAccessControl(_ args: [String: Value]) throws -> CallTool.Result {
        let module = args["module"]?.stringValue
        let kind = args["kind"]?.stringValue.flatMap { NodeKind(rawValue: $0) }

        let issues = try queryEngine.auditAccessControl(
            projectId: projectId,
            module: module,
            kind: kind
        )

        if issues.isEmpty {
            return CallTool.Result(content: [.text("No access control issues found.")])
        }

        var output = "Access Control Audit (\(issues.count) issues):\n\n"
        for issue in issues {
            output += "  \(issue.kind) \(issue.name): \(issue.currentAccess) → \(issue.suggestedAccess)"
            if let path = issue.filePath, let line = issue.line {
                output += " — \(shortenPath(path)):\(line)"
            }
            output += "\n    Reason: \(issue.reason)\n"
        }

        output += "\nNote: Analysis based on structural edges (conformsTo, inherits, composesView, usesEnvironment). Type references in function parameters/return types are not yet tracked."
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

    private func formatImpactTree(_ node: ImpactNode, indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)
        var output = prefix
        if let edge = node.edgeKind {
            output += "[\(edge)] "
        }
        output += "\(node.kind) \(node.name)"
        if let path = node.filePath, let line = node.line {
            output += " — \(shortenPath(path)):\(line)"
        }
        output += "\n"
        for child in node.children {
            output += formatImpactTree(child, indent: indent + 1)
        }
        return output
    }

    private func countImpactNodes(_ node: ImpactNode) -> Int {
        1 + node.children.reduce(0) { $0 + countImpactNodes($1) }
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
