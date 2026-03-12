# SwiftLens

A Swift-native [MCP](https://modelcontextprotocol.io) server that builds a code knowledge graph for Swift projects. It parses your codebase using [swift-syntax](https://github.com/swiftlang/swift-syntax), stores symbols and relationships in a SQLite graph database, and exposes 20 query tools over the Model Context Protocol — giving AI assistants deep, structured understanding of your Swift code.

## Features

- **AST-based indexing** — Parses every `.swift` file with SwiftSyntax to extract symbols (types, functions, properties), edges (conformances, containment, type references, calls), and SwiftUI-specific relationships (view composition, environment usage, property wrappers).
- **Compiler-enriched** — Optionally reads the compiler's index store (from `swift build`) to add USRs, compiler-resolved call edges, method overrides, and protocol requirement edges.
- **Incremental** — Only re-parses files that changed since the last index. Force reindex available when needed.
- **SPM-aware** — Automatically discovers modules from `Package.swift`, maps files to targets, and tracks cross-module dependencies.

## Tools

| Tool | Description |
|---|---|
| `read_symbol` | Read the full source implementation of a symbol — actual code, not just metadata |
| `search_symbol` | FTS5 search by name, attribute (`@Observable`, `@State`, etc.), kind, or module |
| `get_symbol` | Full symbol details — members, conformances, extensions, wrappers |
| `symbols_in_file` | All symbols in a file, ordered by line number |
| `find_usages` | Where a symbol is referenced, with optional source context lines |
| `find_conformers` | All types conforming to a protocol, with optional requirement coverage |
| `find_dependencies` | Bidirectional dependency graph for a symbol |
| `impact_analysis` | Transitive blast radius with actionable protocol compile-impact summary |
| `trace_call_graph` | Function-level caller/callee chains with transitive traversal |
| `trace_view_tree` | SwiftUI view composition hierarchy from a root view |
| `check_environment_injection` | Detect missing `@Environment` injections that would crash at runtime |
| `check_protocol_coverage` | Find missing protocol requirement implementations |
| `find_dead_code` | Symbols with zero incoming references |
| `test_coverage` | Which types have tests and which don't |
| `audit_access_control` | Find overly broad access control (`public` used only internally) |
| `diff_since` | Symbol-level diff against a git ref (added/removed/modified) |
| `get_module_graph` | SPM target dependency graph |
| `get_architecture` | High-level overview — modules, protocols, view models, stats |
| `list_extensions` | All extensions of a type across the codebase |
| `cross_module_usage` | Which specific types cross module boundaries |
| `reindex` | Re-index the project (incremental or force) |

## Requirements

- macOS 15+
- Swift 6.2+

## Building

```bash
swift build -c release
```

The binary is at `.build/release/swift-lens`.

## Installation

Copy the built binary somewhere on your `$PATH`:

```bash
cp .build/release/swift-lens ~/.local/bin/swift-lens
```

If you use the index store enrichment features, re-sign after copying (IndexStore uses `dlopen` which invalidates the ad-hoc signature):

```bash
codesign -fs - ~/.local/bin/swift-lens
```

## Configuration

### Claude Code / Cursor

Add a `.mcp.json` file to the root of your Swift project:

```json
{
  "mcpServers": {
    "swift-lens": {
      "command": "swift-lens",
      "args": ["--project", "/absolute/path/to/your/project"]
    }
  }
}
```

### Claude Desktop

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "swift-lens": {
      "command": "/path/to/swift-lens",
      "args": ["--project", "/absolute/path/to/your/project"]
    }
  }
}
```

### Project Config (Optional)

Create a `.swiftlens.json` in your project root to customize behavior:

```json
{
  "excludePaths": ["Generated/", "Vendor/"],
  "extraTargets": []
}
```

## How It Works

1. **Startup** — On first launch, SwiftLens indexes every `.swift` file in the project using SwiftSyntax, building a graph of symbols and relationships stored in SQLite (via [GRDB](https://github.com/groue/GRDB.swift)).
2. **Enrichment** — If a compiler index store is available (`.build/` for SPM), it layers on compiler-resolved data: USRs, precise call edges, override chains, and protocol requirement mappings.
3. **Serving** — The MCP server runs on stdio, exposing all tools to any MCP-compatible client. Queries run against the graph database.
4. **Incremental updates** — Call `reindex` to pick up changes. Only modified files are re-parsed by default.

The database is cached at `~/.cache/swift-lens/` and keyed by project path.

## Dependencies

- [swift-syntax](https://github.com/swiftlang/swift-syntax) — AST parsing
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite database
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP protocol
- [indexstore-db](https://github.com/swiftlang/indexstore-db) — Compiler index store access

## License

MIT
