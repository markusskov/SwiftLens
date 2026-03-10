import MCP

/// All MCP tool definitions for SwiftLens.
enum ToolDefinitions {

    static let allTools: [Tool] = [
        searchSymbol,
        getSymbol,
        findConformers,
        getModuleGraph,
        traceViewTree,
        getArchitecture,
        listExtensions,
        findDependencies,
        reindex,
        findDeadCode,
        checkProtocolCoverage,
        impactAnalysis,
        checkEnvironmentInjection,
        auditAccessControl,
    ]

    static let searchSymbol = Tool(
        name: "search_symbol",
        description: "Search for Swift symbols (types, functions, properties) by name. Uses FTS5 for fast prefix/fuzzy matching.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query (supports prefix matching)"),
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "description": .string("Filter by symbol kind"),
                    "enum": .array([
                        .string("struct"), .string("class"), .string("enum"),
                        .string("protocol"), .string("actor"), .string("function"),
                        .string("variable"), .string("extension"), .string("typeAlias"),
                    ]),
                ]),
                "module": .object([
                    "type": .string("string"),
                    "description": .string("Filter by SPM module name"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max results (default 20)"),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let getSymbol = Tool(
        name: "get_symbol",
        description: "Get full details of a symbol including members, conformances, extensions, and property wrapper usage.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Symbol qualified name or simple name"),
                ]),
            ]),
            "required": .array([.string("name")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let findConformers = Tool(
        name: "find_conformers",
        description: "Find all types that conform to a given protocol, including conformances added via extensions.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "protocol": .object([
                    "type": .string("string"),
                    "description": .string("Protocol name to find conformers of"),
                ]),
            ]),
            "required": .array([.string("protocol")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let getModuleGraph = Tool(
        name: "get_module_graph",
        description: "Get the SPM target/module dependency graph showing all targets and their inter-dependencies.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let traceViewTree = Tool(
        name: "trace_view_tree",
        description: "Trace the SwiftUI view composition hierarchy from a root view, showing all child views composed in body properties.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "root_view": .object([
                    "type": .string("string"),
                    "description": .string("Root view name to trace from"),
                ]),
                "max_depth": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum traversal depth (default 10)"),
                ]),
            ]),
            "required": .array([.string("root_view")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let getArchitecture = Tool(
        name: "get_architecture",
        description: "Get a high-level architecture overview: module graph, protocols with conformer counts, view models, environment keys, and statistics.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let listExtensions = Tool(
        name: "list_extensions",
        description: "List all extensions of a type across the codebase, showing added conformances and members per extension.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "type_name": .object([
                    "type": .string("string"),
                    "description": .string("Type name to find extensions of"),
                ]),
            ]),
            "required": .array([.string("type_name")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let findDependencies = Tool(
        name: "find_dependencies",
        description: "Find bidirectional dependencies of a symbol — what it depends on and what depends on it.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "symbol": .object([
                    "type": .string("string"),
                    "description": .string("Symbol name to find dependencies of"),
                ]),
                "direction": .object([
                    "type": .string("string"),
                    "description": .string("Direction: incoming, outgoing, or both (default)"),
                    "enum": .array([.string("incoming"), .string("outgoing"), .string("both")]),
                ]),
            ]),
            "required": .array([.string("symbol")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let reindex = Tool(
        name: "reindex",
        description: "Trigger an incremental re-index of the project. Only re-parses files that have changed since last index.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        annotations: .init(readOnlyHint: false, idempotentHint: true)
    )

    static let findDeadCode = Tool(
        name: "find_dead_code",
        description: "Find potentially dead code — top-level symbols with zero incoming usage edges. Filters out entry points, test targets, protocol requirements, and wrapper properties.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "module": .object([
                    "type": .string("string"),
                    "description": .string("Filter to a specific SPM module"),
                ]),
            ]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let checkProtocolCoverage = Tool(
        name: "check_protocol_coverage",
        description: "Check protocol conformance completeness. Shows which required members each conformer implements vs is missing. Catches missing method implementations before the compiler does.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "protocol": .object([
                    "type": .string("string"),
                    "description": .string("Protocol name to check coverage for"),
                ]),
                "show_satisfied": .object([
                    "type": .string("boolean"),
                    "description": .string("Show implemented members too, not just gaps (default false)"),
                ]),
            ]),
            "required": .array([.string("protocol")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let impactAnalysis = Tool(
        name: "impact_analysis",
        description: "Transitive dependency analysis — walk the full dependency graph recursively to show the blast radius of changing a symbol. Shows the complete chain of types that would be affected.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "symbol": .object([
                    "type": .string("string"),
                    "description": .string("Symbol name to analyze impact for"),
                ]),
                "max_depth": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum traversal depth (default 5)"),
                ]),
                "direction": .object([
                    "type": .string("string"),
                    "description": .string("Direction: incoming (what depends on this), outgoing (what this depends on), or both"),
                    "enum": .array([.string("incoming"), .string("outgoing"), .string("both")]),
                ]),
            ]),
            "required": .array([.string("symbol")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let checkEnvironmentInjection = Tool(
        name: "check_environment_injection",
        description: "Check for missing @Environment injections. Cross-references view tree with .environment() modifier calls to find views that read an @Environment key but no ancestor provides it — which would cause a runtime crash.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let auditAccessControl = Tool(
        name: "audit_access_control",
        description: "Find symbols with overly broad access control. Identifies public symbols only used within the same file (should be internal/private) and internal symbols only used within the same file (should be private).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "module": .object([
                    "type": .string("string"),
                    "description": .string("Filter to a specific SPM module"),
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "description": .string("Filter by symbol kind"),
                    "enum": .array([
                        .string("struct"), .string("class"), .string("enum"),
                        .string("protocol"), .string("actor"), .string("function"),
                        .string("variable"), .string("typeAlias"),
                    ]),
                ]),
            ]),
        ]),
        annotations: .init(readOnlyHint: true)
    )
}
