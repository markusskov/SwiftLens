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
        case "read_symbol":
            return try handleReadSymbol(args)
        case "search_symbol":
            return try handleSearchSymbol(args)
        case "get_symbol":
            return try handleGetSymbol(args)
        case "symbols_in_file":
            return try handleSymbolsInFile(args)
        case "find_usages":
            return try handleFindUsages(args)
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
            return try await handleReindex(args)
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
        case "diff_since":
            return try handleDiffSince(args)
        case "test_coverage":
            return try handleTestCoverage(args)
        case "cross_module_usage":
            return try handleCrossModuleUsage(args)
        case "trace_call_graph":
            return try handleTraceCallGraph(args)
        default:
            return CallTool.Result(
                content: [.text("Unknown tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Individual Handlers

    private func handleReadSymbol(_ args: [String: Value]) throws -> CallTool.Result {
        guard let name = args["name"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: name")], isError: true)
        }

        let contextLines = args["context_lines"]?.intValue ?? 0

        let result = try queryEngine.readSymbol(
            projectId: projectId,
            name: name,
            contextLines: contextLines
        )

        guard let source = result.source,
              let kind = result.kind,
              let qualifiedName = result.qualifiedName,
              let filePath = result.filePath,
              let startLine = result.startLine else {
            var msg = "Symbol '\(name)' not found."
            if let suggestions = result.suggestions, !suggestions.isEmpty {
                msg += " Did you mean:\n" + suggestions.map { "  - \($0)" }.joined(separator: "\n")
            }
            return CallTool.Result(content: [.text(msg)])
        }

        var output = "\(kind) \(qualifiedName) — \(shortenPath(filePath)):\(startLine)"
        if let endLine = result.endLine, endLine != startLine {
            output += "-\(endLine)"
        }
        output += "\n\n\(source)\n"

        return CallTool.Result(content: [.text(output)])
    }

    private func handleSearchSymbol(_ args: [String: Value]) throws -> CallTool.Result {
        let query = args["query"]?.stringValue
        let attribute = args["attribute"]?.stringValue

        let kind = args["kind"]?.stringValue.flatMap { NodeKind(rawValue: $0) }

        guard query != nil || attribute != nil || kind != nil else {
            return CallTool.Result(content: [.text("At least one of 'query', 'attribute', or 'kind' must be provided.")], isError: true)
        }
        let module = args["module"]?.stringValue
        let limit = args["limit"]?.intValue ?? 20

        let results = try queryEngine.searchSymbol(
            projectId: projectId,
            query: query,
            kind: kind,
            module: module,
            attribute: attribute,
            limit: limit
        )

        if results.isEmpty {
            var desc = ""
            if let query { desc += "'\(query)'" }
            if let attribute { desc += (desc.isEmpty ? "" : " with ") + "@\(attribute.hasPrefix("@") ? String(attribute.dropFirst()) : attribute)" }
            return CallTool.Result(content: [.text("No symbols found matching \(desc)")])
        }

        var header = "Found \(results.count) symbol(s)"
        if let attribute {
            let normalized = attribute.hasPrefix("@") ? attribute : "@" + attribute
            header += " with \(normalized)"
        }
        if let query { header += " matching '\(query)'" }
        header += ":\n\n"

        var output = header
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
            let suggestions = try queryEngine.searchSymbol(projectId: projectId, query: name, limit: 5)
            if suggestions.isEmpty {
                return CallTool.Result(content: [.text("Symbol '\(name)' not found")])
            }
            let list = suggestions.map { "  \($0.kind) \($0.qualifiedName)" }.joined(separator: "\n")
            return CallTool.Result(content: [.text("Symbol '\(name)' not found. Did you mean:\n\(list)")])
        }

        let output = formatSymbolDetail(detail)
        return CallTool.Result(content: [.text(output)])
    }

    private func handleSymbolsInFile(_ args: [String: Value]) throws -> CallTool.Result {
        guard let filePath = args["file_path"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: file_path")], isError: true)
        }

        // Resolve relative paths against project root
        let resolvedPath: String
        if filePath.hasPrefix("/") {
            resolvedPath = filePath
        } else {
            resolvedPath = projectRoot + "/" + filePath
        }

        let kind = args["kind"]?.stringValue.flatMap { NodeKind(rawValue: $0) }

        let results = try queryEngine.symbolsInFile(
            projectId: projectId,
            filePath: resolvedPath,
            kind: kind
        )

        if results.isEmpty {
            return CallTool.Result(content: [.text("No symbols found in '\(shortenPath(resolvedPath))'")])
        }

        var output = "Symbols in \(shortenPath(resolvedPath)) (\(results.count)):\n\n"
        for r in results {
            output += "  L\(r.line ?? 0) \(r.kind) \(r.name)"
            if let access = r.accessLevel { output += " (\(access))" }
            if let sig = r.signature { output += " \(sig)" }
            output += "\n"
        }
        return CallTool.Result(content: [.text(output)])
    }

    private func handleFindUsages(_ args: [String: Value]) throws -> CallTool.Result {
        guard let symbol = args["symbol"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: symbol")], isError: true)
        }

        let contextLines = args["context_lines"]?.intValue ?? 0

        let result = try queryEngine.findUsages(projectId: projectId, symbolName: symbol)

        if result.usages.isEmpty {
            if result.symbolKind == "unknown" {
                var msg = "Symbol '\(symbol)' not found."
                if let suggestions = result.suggestions, !suggestions.isEmpty {
                    msg += " Did you mean:\n" + suggestions.map { "  - \($0)" }.joined(separator: "\n")
                }
                return CallTool.Result(content: [.text(msg)])
            }
            return CallTool.Result(content: [.text("No usages found for \(result.symbolKind) '\(symbol)'")])
        }

        var output = "Usages of \(result.symbolKind) \(symbol) (\(result.usages.count) sites):\n"

        if let parent = result.parentTypeName {
            output += "  (member of \(parent) — showing references to parent type)\n"
        }

        // Group by file for readability
        let grouped = Dictionary(grouping: result.usages) { $0.filePath ?? "<unknown>" }
        let sortedFiles = grouped.keys.sorted()

        for file in sortedFiles {
            let sites = grouped[file]!
            output += "\n  \(shortenPath(file)):\n"
            for site in sites {
                output += "    L\(site.line ?? 0) — \(site.usedByKind) \(site.usedBy)"
                if site.context != "type reference" {
                    output += " [\(site.context)]"
                }
                output += "\n"

                // Show source context if requested
                if contextLines > 0, let fp = site.filePath, let ln = site.line {
                    if let ctx = readSourceContext(filePath: fp, line: ln, contextLines: contextLines) {
                        output += ctx.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n")
                        output += "\n"
                    }
                }
            }
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleFindConformers(_ args: [String: Value]) throws -> CallTool.Result {
        guard let protocolName = args["protocol"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: protocol")], isError: true)
        }

        let showRequirements = args["show_requirements"]?.boolValue ?? false

        let results = try queryEngine.findConformers(projectId: projectId, protocolName: protocolName)

        if results.isEmpty {
            return CallTool.Result(content: [.text("No conformers found for protocol '\(protocolName)'")])
        }

        var output = "Types conforming to \(protocolName) (\(results.count)):\n\n"

        if showRequirements {
            // Use protocol coverage to show implemented/missing per conformer
            let coverage = try queryEngine.checkProtocolCoverage(
                projectId: projectId,
                protocolName: protocolName,
                showSatisfied: true
            )

            if !coverage.requirements.isEmpty {
                output += "Protocol requirements:\n"
                for req in coverage.requirements {
                    output += "  \(req.kind) \(req.name)"
                    if let sig = req.signature { output += ": \(sig)" }
                    output += "\n"
                }
                output += "\n"
            }

            for r in results {
                output += "  \(r.kind) \(r.name)"
                if let mod = r.moduleName { output += " [\(mod)]" }
                if let path = r.filePath, let line = r.line {
                    output += " — \(shortenPath(path)):\(line)"
                }

                // Find matching coverage info
                if let conformer = coverage.conformers.first(where: { $0.name == r.name }) {
                    if conformer.missing.isEmpty {
                        output += " — COMPLETE"
                    } else {
                        output += " — MISSING \(conformer.missing.count)"
                    }
                    output += "\n"
                    for name in conformer.missing {
                        output += "    - \(name) (MISSING)\n"
                    }
                } else {
                    output += "\n"
                }
            }
        } else {
            for r in results {
                output += "  \(r.kind) \(r.name)"
                if let mod = r.moduleName { output += " [\(mod)]" }
                if let path = r.filePath, let line = r.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
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

    private func handleReindex(_ args: [String: Value]) async throws -> CallTool.Result {
        let force = args["force"]?.boolValue ?? false
        let indexStorePath = args["index_store_path"]?.stringValue
        let result = try await indexingCoordinator.index(
            projectRoot: projectRoot,
            config: projectConfig,
            force: force,
            indexStorePath: indexStorePath
        )

        let mode = force ? "Full reindex" : "Reindex"
        var output = """
            \(mode) complete:
              Files: \(result.totalFiles) total, \(result.indexedFiles) re-parsed, \(result.deletedFiles) deleted
              Modules: \(result.modules)
              Symbols: \(result.totalSymbols)
              Edges: \(result.totalEdges)
            """

        if let enrichment = result.enrichment {
            output += "\n  Index Store Enrichment:"
            output += "\n    USRs populated: \(enrichment.usrsPopulated)"
            output += "\n    Call edges (compiler-resolved): \(enrichment.callEdgesCreated)"
            output += "\n    Override edges: \(enrichment.overrideEdgesCreated)"
            output += "\n    Requirement edges: \(enrichment.requirementEdgesCreated)"
            output += "\n    Receiver types backfilled: \(enrichment.receiverTypesBackfilled)"
        }

        return CallTool.Result(content: [.text(output)])
    }

    private func handleFindDeadCode(_ args: [String: Value]) throws -> CallTool.Result {
        let module = args["module"]?.stringValue
        let maxRefs = args["max_references"]?.intValue ?? 0

        let results = try queryEngine.findDeadCode(
            projectId: projectId,
            module: module,
            maxReferences: maxRefs
        )

        if results.isEmpty {
            let msg = maxRefs == 0
                ? "No dead code found — all symbols have incoming references."
                : "No symbols found with \(maxRefs) or fewer references."
            return CallTool.Result(content: [.text(msg)])
        }

        let dead = results.filter { $0.referenceCount == 0 }
        let nearDead = results.filter { $0.referenceCount > 0 }

        var output = ""

        if !dead.isEmpty {
            output += "DEAD CODE — 0 references (\(dead.count)):\n\n"
            for entry in dead {
                output += "  \(entry.kind) \(entry.name)"
                if let mod = entry.moduleName { output += " [\(mod)]" }
                if let path = entry.filePath, let line = entry.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
        }

        if !nearDead.isEmpty {
            output += "\nNEAR-DEAD CODE — 1-\(maxRefs) reference(s) (\(nearDead.count)):\n\n"
            for entry in nearDead {
                output += "  \(entry.kind) \(entry.name) [\(entry.referenceCount) ref]"
                if let mod = entry.moduleName { output += " [\(mod)]" }
                if let path = entry.filePath, let line = entry.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
        }

        output += "\nNote: Symbols used only via runtime reflection or string-based lookup may be false positives."
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

            // Add actionable protocol summary if applicable
            output += formatProtocolImpactSummary(symbolName: symbol)

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

        // Add actionable protocol summary if applicable
        if direction == .incoming {
            output += formatProtocolImpactSummary(symbolName: symbol)
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

    private func handleDiffSince(_ args: [String: Value]) throws -> CallTool.Result {
        guard let commit = args["commit"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: commit")], isError: true)
        }

        let limit = args["limit"]?.intValue ?? 100
        let unlimited = limit == 0

        // 1. Get changed files with status
        let diffOutput: String
        do {
            diffOutput = try runGit(["diff", "--name-status", commit, "--", "*.swift"], at: projectRoot)
        } catch {
            return CallTool.Result(
                content: [.text("Git error: \(error.localizedDescription)\nMake sure '\(commit)' is a valid git ref.")],
                isError: true
            )
        }

        guard !diffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CallTool.Result(content: [.text("No Swift file changes since '\(commit)'.")])
        }

        var addedFiles: [String] = []
        var modifiedFiles: [String] = []
        var deletedFiles: [String] = []

        for line in diffOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 2 else { continue }
            let status = parts[0]
            // For renames (R###), take the new path (second tab-separated value)
            let filePart: String
            if status.hasPrefix("R") {
                let renameParts = line.split(separator: "\t")
                guard renameParts.count >= 3 else { continue }
                filePart = String(renameParts[2])
            } else {
                filePart = String(parts[1])
            }
            let file = projectRoot + "/" + filePart

            switch status.first {
            case "A": addedFiles.append(file)
            case "M": modifiedFiles.append(file)
            case "D": deletedFiles.append(file)
            case "R": modifiedFiles.append(file)
            default: break
            }
        }

        let totalFiles = addedFiles.count + modifiedFiles.count + deletedFiles.count

        // 2. Get current symbols in added + modified files
        var currentSymbolsByFile: [String: [SymbolSearchResult]] = [:]
        for file in addedFiles + modifiedFiles {
            let symbols = try queryEngine.symbolsInFile(projectId: projectId, filePath: file)
            currentSymbolsByFile[file] = symbols
        }

        // 3. Parse old versions of modified + deleted files
        let indexer = SwiftFileIndexer()
        var oldSymbolsByFile: [String: [ExtractedDeclaration]] = [:]
        for file in modifiedFiles + deletedFiles {
            let relativePath = file.hasPrefix(projectRoot)
                ? String(file.dropFirst(projectRoot.count + 1))
                : file
            if let oldSource = try? runGit(["show", "\(commit):\(relativePath)"], at: projectRoot) {
                let extraction = indexer.index(source: oldSource, filePath: file)
                // Filter out extensions, files, modules — only real declarations
                oldSymbolsByFile[file] = extraction.declarations.filter {
                    $0.kind != .extension && $0.kind != .file && $0.kind != .module
                }
            }
        }

        // 4. Compute diff
        var added: [SymbolChange] = []
        var removed: [SymbolChange] = []
        var modified: [SymbolChange] = []

        // Added files: all current symbols are new
        for file in addedFiles {
            for sym in currentSymbolsByFile[file] ?? [] {
                guard sym.kind != "extension" && sym.kind != "file" && sym.kind != "module" else { continue }
                added.append(SymbolChange(
                    name: sym.qualifiedName, kind: sym.kind,
                    filePath: file, line: sym.line, detail: sym.signature
                ))
            }
        }

        // Deleted files: all old symbols are removed
        for file in deletedFiles {
            for decl in oldSymbolsByFile[file] ?? [] {
                removed.append(SymbolChange(
                    name: decl.parent != nil ? decl.parent! + "." + decl.name : decl.name,
                    kind: decl.kind.rawValue,
                    filePath: file, line: decl.line, detail: decl.signature
                ))
            }
        }

        // Modified files: compare old vs new
        for file in modifiedFiles {
            let oldDecls = oldSymbolsByFile[file] ?? []
            let newSyms = currentSymbolsByFile[file] ?? []

            // Build lookup keys: (name, kind, parent) → symbol
            struct SymbolKey: Hashable {
                let name: String
                let kind: String
                let parent: String?
            }

            var oldByKey: [SymbolKey: ExtractedDeclaration] = [:]
            for decl in oldDecls {
                let key = SymbolKey(name: decl.name, kind: decl.kind.rawValue, parent: decl.parent)
                oldByKey[key] = decl
            }

            var newByKey: [SymbolKey: SymbolSearchResult] = [:]
            for sym in newSyms {
                guard sym.kind != "extension" && sym.kind != "file" && sym.kind != "module" else { continue }
                // Extract parent from qualifiedName (e.g. "Parent.child" → "Parent")
                let parent: String? = sym.qualifiedName.contains(".")
                    ? String(sym.qualifiedName.split(separator: ".").dropLast().joined(separator: "."))
                    : nil
                let key = SymbolKey(name: sym.name, kind: sym.kind, parent: parent)
                newByKey[key] = sym
            }

            // Added: in new but not in old
            for (key, sym) in newByKey where oldByKey[key] == nil {
                added.append(SymbolChange(
                    name: sym.qualifiedName, kind: sym.kind,
                    filePath: file, line: sym.line, detail: sym.signature
                ))
            }

            // Removed: in old but not in new
            for (key, decl) in oldByKey where newByKey[key] == nil {
                removed.append(SymbolChange(
                    name: decl.parent != nil ? decl.parent! + "." + decl.name : decl.name,
                    kind: decl.kind.rawValue,
                    filePath: file, line: decl.line, detail: decl.signature
                ))
            }

            // Modified: in both but signature changed
            for (key, newSym) in newByKey {
                guard let oldDecl = oldByKey[key] else { continue }
                if oldDecl.signature != newSym.signature {
                    let detail: String
                    if let oldSig = oldDecl.signature, let newSig = newSym.signature {
                        detail = oldSig + " → " + newSig
                    } else if let newSig = newSym.signature {
                        detail = "(none) → " + newSig
                    } else if let oldSig = oldDecl.signature {
                        detail = oldSig + " → (none)"
                    } else {
                        continue // Both nil, not really modified
                    }
                    modified.append(SymbolChange(
                        name: newSym.qualifiedName, kind: newSym.kind,
                        filePath: file, line: newSym.line, detail: detail
                    ))
                }
            }
        }

        // 5. Format output
        let totalChanges = added.count + removed.count + modified.count
        if totalChanges == 0 {
            return CallTool.Result(content: [.text("No symbol-level changes since '\(commit)' (\(totalFiles) files changed, but no declaration differences).")])
        }

        var output = "Changes since '\(commit)' — \(totalFiles) files, \(totalChanges) symbol changes:\n"

        func formatSection(_ label: String, _ prefix: String, _ symbols: [SymbolChange]) {
            guard !symbols.isEmpty else { return }
            let sorted = symbols.sorted { $0.name < $1.name }
            let capped = unlimited ? sorted : Array(sorted.prefix(limit))
            output += "\n\(label) (\(symbols.count)):\n"
            for sym in capped {
                output += "  \(prefix) \(sym.kind) \(sym.name)"
                if let path = sym.filePath, let line = sym.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                if let detail = sym.detail {
                    if prefix == "~" {
                        output += "\n    \(detail)"
                    } else {
                        output += " \(detail)"
                    }
                }
                output += "\n"
            }
            if capped.count < symbols.count {
                output += "  ... and \(symbols.count - capped.count) more (use limit=0 for full list)\n"
            }
        }

        formatSection("ADDED", "+", added)
        formatSection("REMOVED", "-", removed)
        formatSection("MODIFIED", "~", modified)

        return CallTool.Result(content: [.text(output)])
    }

    private func handleTestCoverage(_ args: [String: Value]) throws -> CallTool.Result {
        let module = args["module"]?.stringValue
        let showTested = args["show_tested"]?.boolValue ?? false

        let result = try queryEngine.testCoverage(
            projectId: projectId,
            module: module
        )

        if result.totalProductionTypes == 0 {
            return CallTool.Result(content: [.text("No production types found." + (module != nil ? " Check module name." : ""))])
        }

        let pct = String(format: "%.1f", result.coveragePercent)
        let logicPct = String(format: "%.1f", result.logicCoveragePercent)
        var output = "Test Coverage"
        if let module { output += " [\(module)]" }
        output += ":\n"
        output += "  All types: \(result.totalProductionTypes) total, \(result.testedCount) tested (\(pct)%)\n"
        output += "  Logic types: \(result.logicTypes) total, \(result.logicTestedCount) tested (\(logicPct)%)\n"
        output += "  View types: \(result.viewTypes) (excluded from logic coverage)\n"

        if !result.untested.isEmpty {
            output += "\nUNTESTED (\(result.untestedCount)):\n"

            // Group by module
            let grouped = Dictionary(grouping: result.untested) { $0.moduleName ?? "(no module)" }
            let sortedModules = grouped.keys.sorted()

            for mod in sortedModules {
                let entries = grouped[mod]!
                if sortedModules.count > 1 {
                    output += "\n  [\(mod)]:\n"
                }
                let logicEntries = entries.filter { !$0.isView }
                let viewEntries = entries.filter(\.isView)
                for entry in logicEntries {
                    output += "  \(entry.kind) \(entry.name)"
                    if let path = entry.filePath, let line = entry.line {
                        output += " — \(shortenPath(path)):\(line)"
                    }
                    output += "\n"
                }
                if !viewEntries.isEmpty {
                    output += "  — \(viewEntries.count) view(s): \(viewEntries.map(\.name).joined(separator: ", "))\n"
                }
            }
        }

        if showTested && !result.tested.isEmpty {
            output += "\nTESTED (\(result.testedCount)):\n"

            let grouped = Dictionary(grouping: result.tested) { $0.moduleName ?? "(no module)" }
            let sortedModules = grouped.keys.sorted()

            for mod in sortedModules {
                let entries = grouped[mod]!
                if sortedModules.count > 1 {
                    output += "\n  [\(mod)]:\n"
                }
                for entry in entries {
                    output += "  \(entry.kind) \(entry.name)"
                    if let testedBy = entry.testedBy {
                        output += " ← \(testedBy)"
                    }
                    if let path = entry.filePath, let line = entry.line {
                        output += " — \(shortenPath(path)):\(line)"
                    }
                    output += "\n"
                }
            }
        }

        output += "\nNote: CodingKeys enums auto-filtered. Logic coverage excludes View conformers. Detection via naming (FooTests→Foo) + type references from test files."
        return CallTool.Result(content: [.text(output)])
    }

    private func handleCrossModuleUsage(_ args: [String: Value]) throws -> CallTool.Result {
        guard let module = args["module"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: module")], isError: true)
        }

        let targetModule = args["target_module"]?.stringValue

        let result = try queryEngine.crossModuleUsage(
            projectId: projectId,
            module: module,
            targetModule: targetModule
        )

        if result.dependencies.isEmpty {
            return CallTool.Result(content: [.text("No cross-module type usage found from '\(module)'." + (targetModule != nil ? " Check module names." : ""))])
        }

        var output = "Cross-module usage from \(module) — \(result.totalCrossModuleTypes) types across \(result.dependencies.count) module(s):\n"

        for dep in result.dependencies {
            output += "\n→ \(dep.moduleName) (\(dep.types.count) types):\n"
            for entry in dep.types {
                output += "  \(entry.kind) \(entry.typeName) (\(entry.usageCount)x)"
                if let path = entry.filePath, let line = entry.line {
                    output += " — \(shortenPath(path)):\(line)"
                }
                output += "\n"
            }
        }

        return CallTool.Result(content: [.text(output)])
    }

    /// Run a git command and return stdout.
    private func runGit(_ arguments: [String], at workingDirectory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingDirectory] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SwiftLens", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed with exit code \(process.terminationStatus)"])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Protocol Impact Summary

    /// For protocols, generate actionable compile-impact: which conformers will break and where.
    private func formatProtocolImpactSummary(symbolName: String) -> String {
        guard let coverage = try? queryEngine.checkProtocolCoverage(
            projectId: projectId,
            protocolName: symbolName,
            showSatisfied: false
        ), !coverage.conformers.isEmpty else {
            return ""
        }

        var output = "\n== Compile Impact (protocol conformers) ==\n"
        output += "If you add/change a requirement on \(symbolName), these \(coverage.conformers.count) type(s) need updating:\n\n"

        for conformer in coverage.conformers {
            output += "  \(conformer.kind) \(conformer.name)"
            if let path = conformer.filePath, let line = conformer.line {
                output += " — \(shortenPath(path)):\(line)"
            }
            if !conformer.missing.isEmpty {
                output += " (already missing: \(conformer.missing.joined(separator: ", ")))"
            }
            output += "\n"
        }

        return output
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

    private func handleTraceCallGraph(_ args: [String: Value]) throws -> CallTool.Result {
        guard let function = args["function"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: function")], isError: true)
        }

        let maxDepth = args["max_depth"]?.intValue ?? 5
        let directionStr = args["direction"]?.stringValue ?? "both"
        let direction: DependencyDirection = switch directionStr {
        case "incoming": .incoming
        case "outgoing": .outgoing
        default: .both
        }

        let result = try queryEngine.traceCallGraph(
            projectId: projectId,
            functionName: function,
            direction: direction,
            maxDepth: maxDepth
        )

        if result.kind == "unknown" {
            return CallTool.Result(content: [.text("Function '\(function)' not found. Try a different name or use search_symbol to find the exact function name.")])
        }

        let displayName: String
        if let parent = result.parentType {
            displayName = parent + "." + result.functionName
        } else {
            displayName = result.functionName
        }

        var output = "Call Graph for \(displayName)"
        if let path = result.filePath, let line = result.line {
            output += " — " + shortenPath(path) + ":" + String(line)
        }
        output += "\n"

        if direction == .incoming || direction == .both {
            output += "\n== Callers (who calls \(displayName)) ==\n"
            if result.callers.isEmpty {
                output += "  (none found)\n"
            } else {
                var lastDepth = 0
                for node in result.callers {
                    let indent = String(repeating: "  ", count: node.depth)
                    if node.depth > lastDepth + 1 {
                        output += "\n"
                    }
                    output += indent + node.kind + " " + node.name
                    if let path = node.filePath, let line = node.line {
                        output += " — " + shortenPath(path) + ":" + String(line)
                    }
                    output += "\n"
                    lastDepth = node.depth
                }
                output += "  Total: " + String(result.callers.count) + " caller(s)\n"
            }
        }

        if direction == .outgoing || direction == .both {
            output += "\n== Callees (what \(displayName) calls) ==\n"
            if result.callees.isEmpty {
                output += "  (none found)\n"
            } else {
                var lastDepth = 0
                for node in result.callees {
                    let indent = String(repeating: "  ", count: node.depth)
                    if node.depth > lastDepth + 1 {
                        output += "\n"
                    }
                    output += indent + node.kind + " " + node.name
                    if let path = node.filePath, let line = node.line {
                        output += " — " + shortenPath(path) + ":" + String(line)
                    }
                    output += "\n"
                    lastDepth = node.depth
                }
                output += "  Total: " + String(result.callees.count) + " callee(s)\n"
            }
        }

        return CallTool.Result(content: [.text(output)])
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
        if let context = node.context {
            output += " [\(context)]"
        }
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
