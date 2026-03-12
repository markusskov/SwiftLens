import MCP

/// All MCP tool definitions for SwiftLens.
enum ToolDefinitions {

    static let allTools: [Tool] = [
        readSymbol,
        searchSymbol,
        getSymbol,
        symbolsInFile,
        findUsages,
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
        diffSince,
        testCoverage,
        crossModuleUsage,
        traceCallGraph,
    ]

    static let readSymbol = Tool(
        name: "read_symbol",
        description: "Read the full source implementation of a symbol. Given a symbol name, returns the actual source code lines from disk — not just metadata. This is the fastest way to see how something is implemented without reading the whole file.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Symbol name or qualified name (e.g. 'MovieService', 'MovieService.fetchMovie', 'TMDBQuerying')"),
                ]),
                "context_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Extra lines of context above/below the symbol (default 0)"),
                ]),
            ]),
            "required": .array([.string("name")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let searchSymbol = Tool(
        name: "search_symbol",
        description: "Search for Swift symbols by name, attribute, or both. Uses FTS5 for fast prefix/fuzzy matching on names. Attribute search finds types with specific decorators (e.g. @MainActor, @Observable) and properties with specific wrappers (e.g. @Environment, @State). At least one of query or attribute must be provided.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query for symbol name (supports prefix matching). Optional if attribute is provided."),
                ]),
                "attribute": .object([
                    "type": .string("string"),
                    "description": .string("Filter by attribute or property wrapper (e.g. \"@MainActor\", \"Observable\", \"Environment\", \"State\"). Searches both type-level attributes and property wrapper usage."),
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

    static let symbolsInFile = Tool(
        name: "symbols_in_file",
        description: "List all symbols defined in a specific file, ordered by line number. Useful for understanding file contents without reading source.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute or project-relative file path"),
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
            ]),
            "required": .array([.string("file_path")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let findUsages = Tool(
        name: "find_usages",
        description: "Find all usage sites of a symbol with file:line locations. For types, shows exact reference locations from type annotations, initializer calls, and static member access. For members (functions/properties), shows references to the parent type as an approximation. Use context_lines to see surrounding source code at each site.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "symbol": .object([
                    "type": .string("string"),
                    "description": .string("Symbol name to find usages of"),
                ]),
                "context_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Lines of source context to show around each usage site (default 0 — locations only, 2-3 recommended for code review)"),
                ]),
            ]),
            "required": .array([.string("symbol")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let findConformers = Tool(
        name: "find_conformers",
        description: "Find all types that conform to a given protocol, including conformances added via extensions. Use show_requirements=true to see which protocol methods each conformer implements or is missing — essential when adding a new method to a protocol.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "protocol": .object([
                    "type": .string("string"),
                    "description": .string("Protocol name to find conformers of"),
                ]),
                "show_requirements": .object([
                    "type": .string("boolean"),
                    "description": .string("Show implemented/missing protocol requirements per conformer (default false)"),
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
        description: "Trigger a re-index of the project. By default only re-parses files changed since last index. Use force=true to re-parse all files. If an index store is available (from `swift build`), enriches the graph with compiler-resolved USRs, call edges, and override/requirement relationships.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "force": .object([
                    "type": .string("boolean"),
                    "description": .string("Force full re-parse of all files, ignoring file hashes (default false)"),
                ]),
                "index_store_path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the index store directory (auto-detected from .build/ if not provided)"),
                ]),
            ]),
        ]),
        annotations: .init(readOnlyHint: false, idempotentHint: true)
    )

    static let findDeadCode = Tool(
        name: "find_dead_code",
        description: "Find potentially dead code — symbols with zero or few incoming usage edges. With max_references=0 (default), finds completely dead code. With max_references=1+, also surfaces near-dead symbols that may only be referenced by a test.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "module": .object([
                    "type": .string("string"),
                    "description": .string("Filter to a specific SPM module"),
                ]),
                "max_references": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum incoming references to include (default 0 = truly dead only, 1 = also near-dead with single reference)"),
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
        description: "Transitive dependency analysis — walk the full dependency graph recursively to show the blast radius of changing a symbol. Shows the complete chain of types that would be affected. For protocols, includes an actionable summary of which conformers would need updating and in which files.",
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

    static let diffSince = Tool(
        name: "diff_since",
        description: "Show symbols added, removed, or changed since a git ref (branch, tag, or commit SHA). Compares the old source at that ref with the current index to produce a structured diff of symbol-level changes — useful for PR review and understanding what changed.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "commit": .object([
                    "type": .string("string"),
                    "description": .string("Git ref to compare against (branch name, tag, or commit SHA, e.g. 'main', 'v1.0', 'abc1234')"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max symbols per section — added/removed/modified (default 100). Use 0 for unlimited."),
                ]),
            ]),
            "required": .array([.string("commit")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let testCoverage = Tool(
        name: "test_coverage",
        description: "Find which types have tests and which don't. Cross-references test targets with production code using naming conventions (FooTests → Foo) and type reference analysis from test files. Shows coverage percentage and lists untested types.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "module": .object([
                    "type": .string("string"),
                    "description": .string("Filter to a specific production module"),
                ]),
                "show_tested": .object([
                    "type": .string("boolean"),
                    "description": .string("Also show tested types with their test counterparts (default false — only untested)"),
                ]),
            ]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let crossModuleUsage = Tool(
        name: "cross_module_usage",
        description: "Show which specific types a module imports from other modules. Reveals the actual API surface used across module boundaries — not just the module dependency edge, but which protocols, types, and enums cross the boundary. Useful for validating module boundaries and catching over-broad imports.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "module": .object([
                    "type": .string("string"),
                    "description": .string("Source module to analyze (e.g. 'RyvusFeatures')"),
                ]),
                "target_module": .object([
                    "type": .string("string"),
                    "description": .string("Filter to a specific target module (optional)"),
                ]),
            ]),
            "required": .array([.string("module")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )

    static let traceCallGraph = Tool(
        name: "trace_call_graph",
        description: "Trace the call graph of a function — who calls it (callers) and what it calls (callees), with transitive chain analysis. Supports self.method(), Type.staticMethod(), Type.shared.method(), typed local variables, free functions, and initializer calls.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "function": .object([
                    "type": .string("string"),
                    "description": .string("Function name (e.g. 'fetchMovie') or qualified name (e.g. 'MovieService.fetchMovie')"),
                ]),
                "direction": .object([
                    "type": .string("string"),
                    "description": .string("Direction: incoming (callers), outgoing (callees), or both (default)"),
                    "enum": .array([.string("incoming"), .string("outgoing"), .string("both")]),
                ]),
                "max_depth": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum traversal depth for transitive calls (default 5)"),
                ]),
            ]),
            "required": .array([.string("function")]),
        ]),
        annotations: .init(readOnlyHint: true)
    )
}
