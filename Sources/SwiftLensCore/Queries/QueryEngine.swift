import GRDB
import Foundation

/// Central query engine providing all MCP tool implementations.
public struct QueryEngine: Sendable {
    private let db: GraphDatabase

    public init(db: GraphDatabase) {
        self.db = db
    }

    // MARK: - read_symbol

    /// Read the full source implementation of a symbol from disk.
    public func readSymbol(
        projectId: Int64,
        name: String,
        contextLines: Int = 0
    ) throws -> ReadSymbolResult {
        let record = try db.dbWriter.read { db -> SymbolRecord? in
            // 1. Exact name match (prefer non-extension, non-file)
            var symbol = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == name)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .filter(Column("kind") != NodeKind.file.rawValue)
                .filter(Column("kind") != NodeKind.module.rawValue)
                .filter(sql: "qualifiedName NOT LIKE 'unresolved:%'")
                .fetchOne(db)

            // 2. Qualified name match
            if symbol == nil {
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("qualifiedName") == name)
                    .filter(sql: "qualifiedName NOT LIKE 'unresolved:%'")
                    .fetchOne(db)
            }

            // 3. Extension match (e.g. "extension Array")
            if symbol == nil {
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("name") == name)
                    .filter(Column("kind") == NodeKind.extension.rawValue)
                    .fetchOne(db)
            }

            return symbol
        }

        guard let record, let filePath = record.filePath, let startLine = record.line else {
            // Try FTS suggestions
            let suggestions = try db.dbWriter.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT s.name, s.qualifiedName, s.kind
                    FROM symbols s
                    JOIN symbols_fts ON symbols_fts.rowid = s.rowid
                    WHERE symbols_fts MATCH ?
                    AND s.projectId = ?
                    AND s.qualifiedName NOT LIKE 'unresolved:%'
                    AND s.kind NOT IN ('file', 'module')
                    ORDER BY rank LIMIT 5
                    """, arguments: [ftsQuery(name), projectId])
                    .map { (row: Row) -> String in
                        let n: String = row["name"]
                        let qn: String = row["qualifiedName"]
                        let kind: String = row["kind"]
                        return "\(kind) \(qn == n ? n : qn)"
                    }
            }
            return ReadSymbolResult(
                symbolName: name, kind: nil, qualifiedName: nil,
                filePath: nil, startLine: nil, endLine: nil,
                source: nil, suggestions: suggestions, stale: false
            )
        }

        let endLine = record.endLine ?? startLine

        // Check if file changed since last index (staleness detection)
        let stale: Bool = {
            guard let storedHash = try? db.dbWriter.read({ db in
                try String.fetchOne(db, sql: """
                    SELECT sha256 FROM file_hashes
                    WHERE projectId = ? AND filePath = ?
                    """, arguments: [projectId, filePath])
            }) else { return false }
            guard let currentHash = try? FileHasher().hash(filePath: filePath) else { return false }
            return storedHash != currentHash
        }()

        // Read source from disk
        let readStart = max(1, startLine - contextLines)
        let readEnd = endLine + contextLines

        let source: String?
        if FileManager.default.fileExists(atPath: filePath) {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let allLines = content.components(separatedBy: "\n")
            let safeEnd = min(readEnd, allLines.count)
            if readStart <= safeEnd {
                let slice = allLines[(readStart - 1)..<safeEnd]
                source = slice.enumerated().map { offset, line in
                    let lineNum = readStart + offset
                    return String(format: "%4d | %@", lineNum, line)
                }.joined(separator: "\n")
            } else {
                source = nil
            }
        } else {
            source = nil
        }

        return ReadSymbolResult(
            symbolName: record.name,
            kind: record.kind,
            qualifiedName: record.qualifiedName,
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            source: source,
            suggestions: nil,
            stale: stale
        )
    }

    // MARK: - search_symbol

    /// Search for symbols by name and/or attribute.
    public func searchSymbol(
        projectId: Int64,
        query: String? = nil,
        kind: NodeKind? = nil,
        module: String? = nil,
        attribute: String? = nil,
        limit: Int = 20
    ) throws -> [SymbolSearchResult] {
        try db.dbWriter.read { db in
            var sql: String
            var arguments: [any DatabaseValueConvertible]

            if let query {
                // FTS5 text search path
                sql = """
                    SELECT s.*, m.name AS moduleName
                    FROM symbols s
                    JOIN symbols_fts ON symbols_fts.rowid = s.rowid
                    LEFT JOIN modules m ON s.moduleId = m.id
                    LEFT JOIN modules mf ON mf.projectId = s.projectId
                        AND s.moduleId IS NULL AND mf.path IS NOT NULL
                        AND s.filePath LIKE '%/' || mf.path || '/%'
                    WHERE symbols_fts MATCH ?
                    AND s.projectId = ?
                    """
                arguments = [ftsQuery(query), projectId]
            } else {
                // Direct query path (kind-only or attribute-only search)
                sql = """
                    SELECT s.*, COALESCE(m.name, mf.name) AS moduleName
                    FROM symbols s
                    LEFT JOIN modules m ON s.moduleId = m.id
                    LEFT JOIN modules mf ON mf.projectId = s.projectId
                        AND s.moduleId IS NULL AND mf.path IS NOT NULL
                        AND s.filePath LIKE '%/' || mf.path || '/%'
                    WHERE s.projectId = ?
                    """
                arguments = [projectId]
            }

            // Exclude unresolved placeholder symbols
            sql += " AND s.qualifiedName NOT LIKE 'unresolved:%'"

            if let kind {
                sql += " AND s.kind = ?"
                arguments.append(kind.rawValue)
            }

            if let module {
                sql += " AND COALESCE(m.name, mf.name) = ?"
                arguments.append(module)
            }

            if let attribute {
                let normalized = attribute.hasPrefix("@")
                    ? String(attribute.dropFirst()) : attribute
                // Match type-level attributes (stored as @Name in JSON)
                // OR property wrapper usage (stored as Name without @)
                sql += """
                     AND (
                        s.attributes LIKE ?
                        OR EXISTS (
                            SELECT 1 FROM wrapper_usage wu
                            WHERE wu.symbolId = s.id AND wu.wrapperName = ?
                        )
                    )
                    """
                arguments.append("%\"@" + normalized + "\"%")
                arguments.append(normalized)
            }

            sql += query != nil ? " ORDER BY rank LIMIT ?" : " ORDER BY s.name LIMIT ?"
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { row in
                    SymbolSearchResult(
                        id: row["id"],
                        name: row["name"],
                        qualifiedName: row["qualifiedName"],
                        kind: row["kind"],
                        moduleName: row["moduleName"],
                        filePath: row["filePath"],
                        line: row["line"],
                        accessLevel: row["accessLevel"],
                        signature: row["signature"]
                    )
                }
        }
    }

    // MARK: - symbols_in_file

    /// List all symbols defined in a specific file.
    public func symbolsInFile(
        projectId: Int64,
        filePath: String,
        kind: NodeKind? = nil
    ) throws -> [SymbolSearchResult] {
        try db.dbWriter.read { db in
            var sql = """
                SELECT s.*, m.name AS moduleName
                FROM symbols s
                LEFT JOIN modules m ON s.moduleId = m.id
                WHERE s.projectId = ?
                AND s.filePath = ?
                AND s.qualifiedName NOT LIKE 'unresolved:%'
                AND s.qualifiedName NOT LIKE 'file:%'
                """
            var arguments: [any DatabaseValueConvertible] = [projectId, filePath]

            if let kind {
                sql += " AND s.kind = ?"
                arguments.append(kind.rawValue)
            }

            sql += " ORDER BY s.line, s.name"

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { row in
                    SymbolSearchResult(
                        id: row["id"],
                        name: row["name"],
                        qualifiedName: row["qualifiedName"],
                        kind: row["kind"],
                        moduleName: row["moduleName"],
                        filePath: row["filePath"],
                        line: row["line"],
                        accessLevel: row["accessLevel"],
                        signature: row["signature"]
                    )
                }
        }
    }

    // MARK: - get_symbol

    /// Get full details of a symbol including members, edges, and wrapper usages.
    public func getSymbol(
        projectId: Int64,
        qualifiedName: String? = nil,
        symbolId: Int64? = nil
    ) throws -> SymbolDetail? {
        try db.dbWriter.read { db in
            let symbol: SymbolRecord?
            if let symbolId {
                symbol = try SymbolRecord.fetchOne(db, key: symbolId)
            } else if let qualifiedName {
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("qualifiedName") == qualifiedName)
                    .fetchOne(db)
            } else {
                return nil
            }

            guard let symbol, let symbolId = symbol.id else { return nil }

            // Get members (CONTAINS edges outward)
            let members = try Row.fetchAll(db, sql: """
                SELECT s.* FROM symbols s
                JOIN edges e ON e.targetId = s.id
                WHERE e.sourceId = ? AND e.kind = ?
                ORDER BY s.line
                """, arguments: [symbolId, EdgeKind.contains.rawValue])
                .map(Self.symbolFromRow)

            // Get conformances/inheritance
            let conformances = try Row.fetchAll(db, sql: """
                SELECT s.name, e.kind FROM edges e
                JOIN symbols s ON e.targetId = s.id
                WHERE e.sourceId = ? AND e.kind IN (?, ?)
                """, arguments: [symbolId, EdgeKind.conformsTo.rawValue, EdgeKind.inherits.rawValue])
                .map { row in
                    RelatedType(name: row["name"], relationship: row["kind"])
                }

            // Get extensions
            let extensions = try Row.fetchAll(db, sql: """
                SELECT s.* FROM symbols s
                JOIN edges e ON e.sourceId = s.id
                WHERE e.targetId = ? AND e.kind = ?
                """, arguments: [symbolId, EdgeKind.extends.rawValue])
                .map(Self.symbolFromRow)

            // Get wrapper usages
            let wrappers = try WrapperUsageRecord
                .filter(Column("symbolId") == symbolId)
                .fetchAll(db)

            // Get module name
            let moduleName: String? = try {
                guard let moduleId = symbol.moduleId else { return nil }
                return try ModuleRecord.fetchOne(db, key: moduleId)?.name
            }()

            return SymbolDetail(
                symbol: symbol,
                moduleName: moduleName,
                members: members,
                conformances: conformances,
                extensions: extensions,
                wrapperUsages: wrappers
            )
        }
    }

    // MARK: - find_conformers

    /// Find all types conforming to a protocol.
    public func findConformers(
        projectId: Int64,
        protocolName: String
    ) throws -> [SymbolSearchResult] {
        try db.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, m.name AS moduleName
                FROM symbols s
                JOIN edges e ON e.sourceId = s.id
                JOIN symbols proto ON e.targetId = proto.id
                LEFT JOIN modules m ON s.moduleId = m.id
                WHERE proto.name = ?
                AND proto.projectId = ?
                AND e.kind = ?
                ORDER BY s.name
                """, arguments: [protocolName, projectId, EdgeKind.conformsTo.rawValue])
                .map { row in
                    SymbolSearchResult(
                        id: row["id"],
                        name: row["name"],
                        qualifiedName: row["qualifiedName"],
                        kind: row["kind"],
                        moduleName: row["moduleName"],
                        filePath: row["filePath"],
                        line: row["line"],
                        accessLevel: row["accessLevel"],
                        signature: row["signature"]
                    )
                }
        }
    }

    // MARK: - get_module_graph

    /// Get the SPM target dependency graph.
    public func getModuleGraph(projectId: Int64) throws -> ModuleGraph {
        try db.dbWriter.read { db in
            let modules = try ModuleRecord
                .filter(Column("projectId") == projectId)
                .fetchAll(db)

            var moduleMap: [Int64: ModuleInfo] = [:]
            for mod in modules {
                guard let id = mod.id else { continue }
                moduleMap[id] = ModuleInfo(
                    name: mod.name,
                    kind: mod.kind,
                    path: mod.path,
                    dependencies: []
                )
            }

            let deps = try ModuleDepRecord.fetchAll(db)
            for dep in deps {
                if let depName = moduleMap[dep.dependencyId]?.name {
                    moduleMap[dep.moduleId]?.dependencies.append(depName)
                }
            }

            return ModuleGraph(modules: Array(moduleMap.values).sorted { $0.name < $1.name })
        }
    }

    // MARK: - trace_view_tree

    /// Trace SwiftUI view composition hierarchy using recursive CTE.
    public func traceViewTree(
        projectId: Int64,
        rootView: String,
        maxDepth: Int = 10
    ) throws -> ViewTreeNode {
        try db.dbWriter.read { db in
            // Find root symbol
            guard let root = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == rootView)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .filter(Column("kind") != NodeKind.file.rawValue)
                .filter(Column("kind") != NodeKind.module.rawValue)
                .fetchOne(db)
            else {
                return ViewTreeNode(name: rootView, filePath: nil, line: nil, context: nil, children: [])
            }

            // Recursive CTE with parent tracking for proper tree reconstruction
            let rows = try Row.fetchAll(db, sql: """
                WITH RECURSIVE view_tree(id, name, filePath, line, depth, parentId, context) AS (
                    SELECT s.id, s.name, s.filePath, s.line, 0, CAST(NULL AS INTEGER), CAST(NULL AS TEXT)
                    FROM symbols s
                    WHERE s.id = ?

                    UNION ALL

                    SELECT child.id, child.name, child.filePath, child.line, vt.depth + 1, vt.id, e.metadata
                    FROM view_tree vt
                    JOIN edges e ON e.sourceId = vt.id AND e.kind = ?
                    JOIN symbols child ON e.targetId = child.id
                    WHERE vt.depth < ?
                )
                SELECT DISTINCT id, name, filePath, line, depth, parentId, context FROM view_tree
                ORDER BY depth, name
                """, arguments: [root.id, EdgeKind.composesView.rawValue, maxDepth])

            return buildViewTree(from: rows, rootName: rootView)
        }
    }

    // MARK: - list_extensions

    /// List all extensions of a type.
    public func listExtensions(
        projectId: Int64,
        typeName: String
    ) throws -> [ExtensionInfo] {
        try db.dbWriter.read { db in
            // Find the base type
            guard let baseType = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == typeName)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .filter(Column("kind") != NodeKind.file.rawValue)
                .fetchOne(db)
            else {
                return []
            }

            // Find all extension symbols targeting this type
            let extensions = try Row.fetchAll(db, sql: """
                SELECT ext.* FROM symbols ext
                JOIN edges e ON e.sourceId = ext.id
                WHERE e.targetId = ?
                AND e.kind = ?
                ORDER BY ext.filePath, ext.line
                """, arguments: [baseType.id, EdgeKind.extends.rawValue])

            var results: [ExtensionInfo] = []
            for extRow in extensions {
                let extId: Int64 = extRow["id"]

                // Get conformances added by this extension
                let inheritedJSON: String? = extRow["inheritedTypes"]
                let conformances = inheritedJSON.flatMap { json in
                    try? JSONDecoder().decode([String].self, from: Data(json.utf8))
                } ?? []

                // Get members added by this extension
                let members = try Row.fetchAll(db, sql: """
                    SELECT s.name, s.kind, s.signature FROM symbols s
                    JOIN edges e ON e.targetId = s.id
                    WHERE e.sourceId = ? AND e.kind = ?
                    """, arguments: [extId, EdgeKind.contains.rawValue])
                    .map { row -> String in
                        let kind: String = row["kind"]
                        let name: String = row["name"]
                        let sig: String? = row["signature"]
                        return "\(kind) \(name)\(sig.map { ": \($0)" } ?? "")"
                    }

                results.append(ExtensionInfo(
                    filePath: extRow["filePath"],
                    line: extRow["line"],
                    conformances: conformances,
                    members: members
                ))
            }

            return results
        }
    }

    // MARK: - find_usages

    /// Find all usage sites of a symbol with file:line locations.
    /// For types, queries the type_references table for exact call sites.
    /// For members, shows references to the parent type as an approximation.
    public func findUsages(
        projectId: Int64,
        symbolName: String
    ) throws -> UsageResult {
        try db.dbWriter.read { db in
            // Try multiple lookup strategies:
            // 1. Exact name match
            // 2. Qualified name match (e.g., "ProfileManager.createProfile")
            // 3. FTS prefix search as last resort
            var symbol = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == symbolName)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .filter(Column("kind") != NodeKind.file.rawValue)
                .filter(Column("kind") != NodeKind.module.rawValue)
                .filter(sql: "qualifiedName NOT LIKE 'unresolved:%'")
                .fetchOne(db)

            if symbol == nil {
                // Try qualified name match
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("qualifiedName") == symbolName)
                    .filter(sql: "qualifiedName NOT LIKE 'unresolved:%'")
                    .fetchOne(db)
            }

            if symbol == nil {
                // Try FTS prefix search — find suggestions
                let suggestions = try Row.fetchAll(db, sql: """
                    SELECT s.name, s.qualifiedName, s.kind
                    FROM symbols s
                    JOIN symbols_fts ON symbols_fts.rowid = s.rowid
                    WHERE symbols_fts MATCH ?
                    AND s.projectId = ?
                    AND s.qualifiedName NOT LIKE 'unresolved:%'
                    AND s.kind NOT IN ('file', 'module', 'extension')
                    ORDER BY rank LIMIT 5
                    """, arguments: [ftsQuery(symbolName), projectId])

                let suggestionNames = suggestions.map { (row: Row) -> String in
                    let name: String = row["name"]
                    let qn: String = row["qualifiedName"]
                    let kind: String = row["kind"]
                    return "\(kind) \(qn == name ? name : qn)"
                }

                return UsageResult(symbolName: symbolName, symbolKind: "unknown",
                                   usages: [], parentTypeName: nil,
                                   suggestions: suggestionNames)
            }

            guard let symbol else {
                return UsageResult(symbolName: symbolName, symbolKind: "unknown",
                                   usages: [], parentTypeName: nil)
            }

            let typeKinds: Set<String> = ["struct", "class", "enum", "actor", "protocol", "typeAlias"]
            let isType = typeKinds.contains(symbol.kind)

            // For members, find the parent type to show type-level references
            var parentTypeName: String? = nil
            var lookupName = symbolName

            if !isType {
                let parentRow = try Row.fetchOne(db, sql: """
                    SELECT s.name FROM symbols s
                    JOIN edges e ON e.sourceId = s.id AND e.kind = ?
                    WHERE e.targetId = ?
                    AND s.kind IN ('struct', 'class', 'enum', 'actor', 'protocol')
                    LIMIT 1
                    """, arguments: [EdgeKind.contains.rawValue, symbol.id!])

                if let parentRow {
                    parentTypeName = parentRow["name"]
                    lookupName = parentTypeName!
                }
            }

            var usages: [UsageSite] = []
            var seen = Set<String>()

            // Type references: exact file:line usage sites from the type_references table
            let refs = try Row.fetchAll(db, sql: """
                SELECT tr.filePath, tr.line,
                       sourceSym.name AS usedBy, sourceSym.kind AS usedByKind
                FROM type_references tr
                JOIN symbols sourceSym ON sourceSym.id = tr.sourceSymbolId
                WHERE tr.projectId = ? AND tr.referencedTypeName = ?
                ORDER BY tr.filePath, tr.line
                """, arguments: [projectId, lookupName])

            for row in refs {
                let fp: String? = row["filePath"]
                let ln: Int? = row["line"]
                let key = "\(fp ?? ""):\(ln ?? 0)"
                guard seen.insert(key).inserted else { continue }

                usages.append(UsageSite(
                    filePath: fp,
                    line: ln,
                    usedBy: row["usedBy"],
                    usedByKind: row["usedByKind"],
                    context: "type reference"
                ))
            }

            // Structural edges (conformsTo, composesView, usesEnvironment, etc.)
            // Use the original symbol's ID for types, or the parent's for members
            let targetId: Int64
            if isType {
                targetId = symbol.id!
            } else if let parentTypeName {
                targetId = try Int64.fetchOne(db, sql: """
                    SELECT id FROM symbols
                    WHERE projectId = ? AND name = ? AND kind IN ('struct', 'class', 'enum', 'actor', 'protocol')
                    AND qualifiedName NOT LIKE 'unresolved:%'
                    LIMIT 1
                    """, arguments: [projectId, parentTypeName]) ?? symbol.id!
            } else {
                targetId = symbol.id!
            }

            let edgeRows = try Row.fetchAll(db, sql: """
                SELECT s.name, s.kind, s.filePath, s.line, e.kind AS edgeKind
                FROM edges e
                JOIN symbols s ON s.id = e.sourceId
                WHERE e.targetId = ?
                AND e.kind NOT IN ('contains', 'extends', 'references')
                ORDER BY e.kind, s.name
                """, arguments: [targetId])

            for row in edgeRows {
                let fp: String? = row["filePath"]
                let ln: Int? = row["line"]
                let key = "\(fp ?? ""):\(ln ?? 0)"
                guard seen.insert(key).inserted else { continue }

                usages.append(UsageSite(
                    filePath: fp,
                    line: ln,
                    usedBy: row["name"],
                    usedByKind: row["kind"],
                    context: row["edgeKind"]
                ))
            }

            return UsageResult(
                symbolName: symbolName,
                symbolKind: symbol.kind,
                usages: usages,
                parentTypeName: parentTypeName
            )
        }
    }

    // MARK: - find_dependencies

    /// Find bidirectional dependencies of a symbol.
    public func findDependencies(
        projectId: Int64,
        symbolName: String,
        direction: DependencyDirection = .both
    ) throws -> DependencyResult {
        try db.dbWriter.read { db in
            guard let symbol = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == symbolName)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .fetchOne(db)
            else {
                return DependencyResult(symbolName: symbolName, dependsOn: [], dependedOnBy: [])
            }

            var dependsOn: [DependencyInfo] = []
            var dependedOnBy: [DependencyInfo] = []

            if direction == .outgoing || direction == .both {
                dependsOn = try Row.fetchAll(db, sql: """
                    SELECT s.name, s.kind, s.filePath, s.line, e.kind AS edgeKind
                    FROM edges e
                    JOIN symbols s ON e.targetId = s.id
                    WHERE e.sourceId = ?
                    ORDER BY e.kind, s.name
                    """, arguments: [symbol.id])
                    .map { row in
                        DependencyInfo(
                            name: row["name"],
                            kind: row["kind"],
                            filePath: row["filePath"],
                            line: row["line"],
                            relationship: row["edgeKind"]
                        )
                    }
            }

            if direction == .incoming || direction == .both {
                dependedOnBy = try Row.fetchAll(db, sql: """
                    SELECT s.name, s.kind, s.filePath, s.line, e.kind AS edgeKind
                    FROM edges e
                    JOIN symbols s ON e.sourceId = s.id
                    WHERE e.targetId = ?
                    ORDER BY e.kind, s.name
                    """, arguments: [symbol.id])
                    .map { row in
                        DependencyInfo(
                            name: row["name"],
                            kind: row["kind"],
                            filePath: row["filePath"],
                            line: row["line"],
                            relationship: row["edgeKind"]
                        )
                    }
            }

            return DependencyResult(
                symbolName: symbolName,
                dependsOn: dependsOn,
                dependedOnBy: dependedOnBy
            )
        }
    }

    // MARK: - get_architecture

    /// High-level architecture overview of the project.
    public func getArchitecture(projectId: Int64) throws -> ArchitectureOverview {
        try db.dbWriter.read { db in
            // Module graph
            let modules = try ModuleRecord
                .filter(Column("projectId") == projectId)
                .fetchAll(db)

            // Protocol count
            let protocolCount = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("kind") == NodeKind.protocol.rawValue)
                .fetchCount(db)

            // Protocols with conformer counts
            let protocolStats = try Row.fetchAll(db, sql: """
                SELECT proto.name, COUNT(DISTINCT e.sourceId) AS conformerCount
                FROM symbols proto
                JOIN edges e ON e.targetId = proto.id AND e.kind = ?
                WHERE proto.projectId = ? AND proto.kind = ?
                GROUP BY proto.name
                ORDER BY conformerCount DESC
                LIMIT 20
                """, arguments: [EdgeKind.conformsTo.rawValue, projectId, NodeKind.protocol.rawValue])
                .map { row in
                    ProtocolStat(name: row["name"], conformerCount: row["conformerCount"])
                }

            // View models: only actual class/struct definitions (not properties named viewModel)
            let vmKinds = [
                NodeKind.class.rawValue,
                NodeKind.struct.rawValue,
            ]
            let viewModels = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(vmKinds.contains(Column("kind")))
                .filter(
                    Column("name").like("%ViewModel") ||
                    Column("attributes").like("%@Observable%")
                )
                .fetchAll(db)
                .map { symbol in
                    ViewModelInfo(
                        name: symbol.name,
                        filePath: symbol.filePath,
                        line: symbol.line
                    )
                }

            // Environment keys
            let envKeys = try EnvironmentKeyRecord
                .filter(Column("projectId") == projectId)
                .fetchAll(db)
                .map { key in
                    EnvironmentKeyInfo(
                        keyName: key.keyName,
                        valueType: key.valueType,
                        filePath: key.filePath,
                        line: key.line
                    )
                }

            // File and symbol counts
            let fileCount = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("kind") == NodeKind.file.rawValue)
                .fetchCount(db)

            let totalSymbols = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .fetchCount(db)

            return ArchitectureOverview(
                modules: modules.map { ModuleInfo(name: $0.name, kind: $0.kind, path: $0.path, dependencies: []) },
                protocolCount: protocolCount,
                protocolStats: protocolStats,
                viewModels: viewModels,
                environmentKeys: envKeys,
                fileCount: fileCount,
                totalSymbols: totalSymbols
            )
        }
    }

    // MARK: - find_dead_code

    /// Find symbols with few or zero incoming usage edges — potential dead code.
    /// When maxReferences > 0, also surfaces "near-dead" symbols with limited usage.
    public func findDeadCode(
        projectId: Int64,
        module: String? = nil,
        maxReferences: Int = 0
    ) throws -> [DeadCodeEntry] {
        try db.dbWriter.read { db in
            var sql = """
                SELECT s.id, s.name, s.kind, s.qualifiedName, s.filePath, s.line,
                       m.name AS moduleName,
                       COUNT(ue.id) AS refCount
                FROM symbols s
                LEFT JOIN modules m ON s.moduleId = m.id
                LEFT JOIN edges ue ON ue.targetId = s.id
                    AND ue.kind NOT IN ('extends', 'contains')
                WHERE s.projectId = ?
                  AND s.kind IN ('struct', 'class', 'enum', 'actor', 'function', 'typeAlias')
                  AND s.qualifiedName NOT LIKE 'unresolved:%'
                  AND s.qualifiedName NOT LIKE 'file:%'
                  AND s.qualifiedName NOT LIKE 'module:%'
                  -- Top-level only: not a member of another type
                  AND NOT EXISTS (
                    SELECT 1 FROM edges ce WHERE ce.targetId = s.id AND ce.kind = 'contains'
                  )
                  -- Not @main entry point
                  AND (s.attributes IS NULL OR s.attributes NOT LIKE '%@main%')
                  -- Not in a test target (by module or file path)
                  AND NOT EXISTS (
                    SELECT 1 FROM modules tm
                    WHERE tm.id = s.moduleId AND tm.kind = 'test'
                  )
                  AND (s.filePath IS NULL OR (s.filePath NOT LIKE '%/Tests/%' AND s.filePath NOT LIKE '%Tests.swift'))
                  -- Not a protocol conformer (used via its protocol, not directly)
                  AND NOT EXISTS (
                    SELECT 1 FROM edges ce
                    WHERE ce.sourceId = s.id AND ce.kind = 'conformsTo'
                  )
                """
            var arguments: [any DatabaseValueConvertible] = [projectId]

            if let module {
                sql += " AND m.name = ?"
                arguments.append(module)
            }

            sql += " GROUP BY s.id HAVING COUNT(ue.id) <= ?"
            arguments.append(maxReferences)

            sql += " ORDER BY COUNT(ue.id), s.kind, s.name"

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { row in
                    DeadCodeEntry(
                        name: row["name"],
                        kind: row["kind"],
                        qualifiedName: row["qualifiedName"],
                        filePath: row["filePath"],
                        line: row["line"],
                        moduleName: row["moduleName"],
                        referenceCount: row["refCount"]
                    )
                }
        }
    }

    // MARK: - check_protocol_coverage

    /// Check which required members each conformer implements vs is missing.
    public func checkProtocolCoverage(
        projectId: Int64,
        protocolName: String,
        showSatisfied: Bool = false
    ) throws -> ProtocolCoverageResult {
        try db.dbWriter.read { db in
            guard let proto = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == protocolName)
                .filter(Column("kind") == NodeKind.protocol.rawValue)
                .fetchOne(db),
                  let protoId = proto.id
            else {
                return ProtocolCoverageResult(protocolName: protocolName, requirements: [], conformers: [])
            }

            // Get required members of the protocol
            let requirements = try Row.fetchAll(db, sql: """
                SELECT s.name, s.kind, s.signature
                FROM symbols s
                JOIN edges e ON e.sourceId = ? AND e.targetId = s.id AND e.kind = ?
                ORDER BY s.kind, s.name
                """, arguments: [protoId, EdgeKind.contains.rawValue])
                .map { row in
                    ProtocolRequirement(
                        name: row["name"],
                        kind: row["kind"],
                        signature: row["signature"]
                    )
                }

            // Find all conformers
            let conformerRows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.name, s.kind, s.filePath, s.line
                FROM symbols s
                JOIN edges e ON e.sourceId = s.id AND e.targetId = ? AND e.kind = ?
                ORDER BY s.name
                """, arguments: [protoId, EdgeKind.conformsTo.rawValue])

            var conformers: [ConformerCoverage] = []

            for conformerRow in conformerRows {
                let conformerId: Int64 = conformerRow["id"]

                // Get all member names of this conformer (direct + from extensions)
                let memberNames = try Set(Row.fetchAll(db, sql: """
                    SELECT s.name FROM symbols s
                    JOIN edges e ON e.targetId = s.id AND e.kind = ?
                    WHERE e.sourceId = ?

                    UNION

                    SELECT s.name FROM symbols s
                    JOIN edges memEdge ON memEdge.targetId = s.id AND memEdge.kind = ?
                    JOIN edges extEdge ON extEdge.sourceId = memEdge.sourceId AND extEdge.kind = ?
                    WHERE extEdge.targetId = ?
                    """, arguments: [
                        EdgeKind.contains.rawValue, conformerId,
                        EdgeKind.contains.rawValue, EdgeKind.extends.rawValue, conformerId,
                    ])
                    .map { (row: Row) -> String in
                        row["name"]
                    })

                let satisfied = requirements.filter { memberNames.contains($0.name) }.map(\.name)
                let missing = requirements.filter { !memberNames.contains($0.name) }.map(\.name)

                conformers.append(ConformerCoverage(
                    name: conformerRow["name"],
                    kind: conformerRow["kind"],
                    filePath: conformerRow["filePath"],
                    line: conformerRow["line"],
                    satisfied: satisfied,
                    missing: missing
                ))
            }

            return ProtocolCoverageResult(
                protocolName: protocolName,
                requirements: requirements,
                conformers: conformers
            )
        }
    }

    // MARK: - impact_analysis

    /// Transitive dependency walk — blast radius for a symbol change.
    public func impactAnalysis(
        projectId: Int64,
        symbolName: String,
        direction: DependencyDirection = .incoming,
        maxDepth: Int = 5
    ) throws -> ImpactNode {
        try db.dbWriter.read { db in
            guard let symbol = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == symbolName)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .filter(Column("kind") != NodeKind.file.rawValue)
                .filter(Column("kind") != NodeKind.module.rawValue)
                .fetchOne(db)
            else {
                return ImpactNode(name: symbolName, kind: "unknown", filePath: nil, line: nil, edgeKind: nil, children: [])
            }

            let cteSQL: String
            if direction == .outgoing {
                cteSQL = """
                    WITH RECURSIVE impact(id, name, kind, filePath, line, depth, parentId, edgeKind) AS (
                        SELECT s.id, s.name, s.kind, s.filePath, s.line, 0, CAST(NULL AS INTEGER), CAST(NULL AS TEXT)
                        FROM symbols s WHERE s.id = ?

                        UNION ALL

                        SELECT dep.id, dep.name, dep.kind, dep.filePath, dep.line,
                               i.depth + 1, i.id, e.kind
                        FROM impact i
                        JOIN edges e ON e.sourceId = i.id
                        JOIN symbols dep ON e.targetId = dep.id
                        WHERE i.depth < ?
                          AND e.kind NOT IN ('contains', 'imports', 'dependsOn')
                          AND dep.kind NOT IN ('file', 'module')
                    )
                    SELECT DISTINCT id, name, kind, filePath, line, depth, parentId, edgeKind
                    FROM impact ORDER BY depth, name
                    """
            } else {
                cteSQL = """
                    WITH RECURSIVE impact(id, name, kind, filePath, line, depth, parentId, edgeKind) AS (
                        SELECT s.id, s.name, s.kind, s.filePath, s.line, 0, CAST(NULL AS INTEGER), CAST(NULL AS TEXT)
                        FROM symbols s WHERE s.id = ?

                        UNION ALL

                        SELECT dep.id, dep.name, dep.kind, dep.filePath, dep.line,
                               i.depth + 1, i.id, e.kind
                        FROM impact i
                        JOIN edges e ON e.targetId = i.id
                        JOIN symbols dep ON e.sourceId = dep.id
                        WHERE i.depth < ?
                          AND e.kind NOT IN ('contains', 'imports', 'dependsOn')
                          AND dep.kind NOT IN ('file', 'module')
                    )
                    SELECT DISTINCT id, name, kind, filePath, line, depth, parentId, edgeKind
                    FROM impact ORDER BY depth, name
                    """
            }

            let rows = try Row.fetchAll(db, sql: cteSQL, arguments: [symbol.id, maxDepth])
            return buildImpactTree(from: rows, rootName: symbolName)
        }
    }

    // MARK: - trace_call_graph

    /// Trace the call graph from a function: callers (incoming) and/or callees (outgoing).
    /// Uses recursive CTEs for transitive call chain analysis.
    public func traceCallGraph(
        projectId: Int64,
        functionName: String,
        direction: DependencyDirection = .both,
        maxDepth: Int = 5
    ) throws -> CallGraphResult {
        try db.dbWriter.read { db in
            // Find the target function — try exact match first, then qualified name
            var symbol = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("name") == functionName)
                .filter(Column("kind") == NodeKind.function.rawValue)
                .fetchOne(db)

            // Try initializer
            if symbol == nil && functionName.hasPrefix("init") {
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("name") == functionName)
                    .filter(Column("kind") == NodeKind.initializer.rawValue)
                    .fetchOne(db)
            }

            // Try qualified name match (e.g. "MovieService.fetchMovie")
            if symbol == nil {
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("qualifiedName") == functionName)
                    .filter(Column("kind") == NodeKind.function.rawValue)
                    .fetchOne(db)
            }

            // Fallback: any symbol with that name
            if symbol == nil {
                symbol = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("name") == functionName)
                    .filter(Column("qualifiedName").like("%.\(functionName)"))
                    .filter([
                        NodeKind.function.rawValue,
                        NodeKind.initializer.rawValue,
                        NodeKind.variable.rawValue,
                    ].contains(Column("kind")))
                    .fetchOne(db)
            }

            guard let symbol, let symbolId = symbol.id else {
                return CallGraphResult(
                    functionName: functionName,
                    kind: "unknown",
                    parentType: nil,
                    filePath: nil,
                    line: nil,
                    callers: [],
                    callees: []
                )
            }

            // Get parent type name
            let parentType: String? = try Row.fetchOne(db, sql: """
                SELECT p.name FROM symbols p
                JOIN edges e ON e.sourceId = p.id AND e.kind = 'contains'
                WHERE e.targetId = ?
                """, arguments: [symbolId])?["name"]

            var callers: [CallGraphNode] = []
            var callees: [CallGraphNode] = []

            // Incoming: who calls this function (recursive)
            if direction == .incoming || direction == .both {
                let rows = try Row.fetchAll(db, sql: """
                    WITH RECURSIVE call_chain(id, name, kind, filePath, line, depth, parentId, parentType, callKind) AS (
                        SELECT s.id, s.name, s.kind, s.filePath, s.line, 0,
                               CAST(NULL AS INTEGER), CAST(NULL AS TEXT), CAST(NULL AS TEXT)
                        FROM symbols s WHERE s.id = ?

                        UNION ALL

                        SELECT caller.id, caller.name, caller.kind, caller.filePath, caller.line,
                               cc.depth + 1, cc.id,
                               parentSym.name,
                               e.metadata
                        FROM call_chain cc
                        JOIN edges e ON e.targetId = cc.id AND e.kind = 'calls'
                        JOIN symbols caller ON e.sourceId = caller.id
                        LEFT JOIN edges pe ON pe.targetId = caller.id AND pe.kind = 'contains'
                        LEFT JOIN symbols parentSym ON pe.sourceId = parentSym.id
                        WHERE cc.depth < ?
                    )
                    SELECT DISTINCT id, name, kind, filePath, line, depth, parentId, parentType, callKind
                    FROM call_chain
                    WHERE depth > 0
                    ORDER BY depth, name
                    """, arguments: [symbolId, maxDepth])

                callers = buildCallNodes(from: rows)
            }

            // Outgoing: what does this function call (recursive)
            if direction == .outgoing || direction == .both {
                let rows = try Row.fetchAll(db, sql: """
                    WITH RECURSIVE call_chain(id, name, kind, filePath, line, depth, parentId, parentType, callKind) AS (
                        SELECT s.id, s.name, s.kind, s.filePath, s.line, 0,
                               CAST(NULL AS INTEGER), CAST(NULL AS TEXT), CAST(NULL AS TEXT)
                        FROM symbols s WHERE s.id = ?

                        UNION ALL

                        SELECT callee.id, callee.name, callee.kind, callee.filePath, callee.line,
                               cc.depth + 1, cc.id,
                               parentSym.name,
                               e.metadata
                        FROM call_chain cc
                        JOIN edges e ON e.sourceId = cc.id AND e.kind = 'calls'
                        JOIN symbols callee ON e.targetId = callee.id
                        LEFT JOIN edges pe ON pe.targetId = callee.id AND pe.kind = 'contains'
                        LEFT JOIN symbols parentSym ON pe.sourceId = parentSym.id
                        WHERE cc.depth < ?
                    )
                    SELECT DISTINCT id, name, kind, filePath, line, depth, parentId, parentType, callKind
                    FROM call_chain
                    WHERE depth > 0
                    ORDER BY depth, name
                    """, arguments: [symbolId, maxDepth])

                callees = buildCallNodes(from: rows)
            }

            return CallGraphResult(
                functionName: functionName,
                kind: symbol.kind,
                parentType: parentType,
                filePath: symbol.filePath,
                line: symbol.line,
                callers: callers,
                callees: callees
            )
        }
    }

    private func buildCallNodes(from rows: [Row]) -> [CallGraphNode] {
        var nodes: [CallGraphNode] = []
        var seen = Set<Int64>()

        for row in rows {
            let id: Int64 = row["id"]
            guard seen.insert(id).inserted else { continue }

            let depth: Int = row["depth"]
            let parentType: String? = row["parentType"]
            let name: String = row["name"]

            let displayName: String
            if let parentType {
                displayName = parentType + "." + name
            } else {
                displayName = name
            }

            nodes.append(CallGraphNode(
                name: displayName,
                kind: row["kind"],
                filePath: row["filePath"],
                line: row["line"],
                depth: depth,
                callKind: row["callKind"]
            ))
        }

        return nodes
    }

    // MARK: - check_environment_injection

    /// SwiftUI system-provided environment keys that don't need manual injection.
    private static let systemEnvironmentKeys: Set<String> = [
        // Focus & interaction
        "\\.isFocused", "\\.resetFocus", "\\.focusedField",
        // Navigation & dismissal
        "\\.dismiss", "\\.isPresented", "\\.presentationMode",
        "\\.openURL", "\\.openWindow", "\\.dismissWindow",
        "\\.supportsMultipleWindows",
        // Layout & geometry
        "\\.horizontalSizeClass", "\\.verticalSizeClass",
        "\\.dynamicTypeSize", "\\.pixelLength",
        "\\.displayScale", "\\.imageScale",
        // Appearance
        "\\.colorScheme", "\\.colorSchemeContrast",
        "\\.accessibilityEnabled", "\\.accessibilityReduceMotion",
        "\\.accessibilityReduceTransparency", "\\.accessibilityDifferentiateWithoutColor",
        "\\.accessibilityInvertColors", "\\.accessibilityShowButtonShapes",
        "\\.legibilityWeight",
        // Locale & calendar
        "\\.locale", "\\.calendar", "\\.timeZone", "\\.layoutDirection",
        // Scene & lifecycle
        "\\.scenePhase", "\\.isSearching", "\\.refresh",
        "\\.editMode", "\\.isEnabled", "\\.isLuminanceReduced",
        // Text & editing
        "\\.font", "\\.lineLimit", "\\.lineSpacing",
        "\\.multilineTextAlignment", "\\.truncationMode",
        "\\.autocorrectionDisabled",
        // Containers
        "\\.managedObjectContext", "\\.modelContext",
        "\\.undoManager", "\\.widgetFamily",
        // tvOS specific
        "\\.backgroundMaterial",
    ]

    /// Check for missing @Environment injections by walking the view tree.
    /// Optionally scoped to a view subtree rooted at `rootView`.
    public func checkEnvironmentInjection(
        projectId: Int64,
        rootView: String? = nil
    ) throws -> [EnvironmentInjectionCheck] {
        try db.dbWriter.read { db in
            // If rootView is specified, collect all view IDs in that subtree
            let subtreeViewIds: Set<Int64>?
            if let rootView {
                let rootRow = try Row.fetchOne(db, sql: """
                    SELECT id FROM symbols
                    WHERE projectId = ? AND name = ?
                      AND kind IN ('struct', 'class')
                      AND qualifiedName NOT LIKE 'unresolved:%'
                    LIMIT 1
                    """, arguments: [projectId, rootView])
                guard let rootId: Int64 = rootRow?["id"] else {
                    return [] // root view not found
                }
                let descendants = try Row.fetchAll(db, sql: """
                    WITH RECURSIVE subtree(viewId, depth) AS (
                        SELECT ?, 0
                        UNION ALL
                        SELECT e.targetId, s.depth + 1
                        FROM subtree s
                        JOIN edges e ON e.sourceId = s.viewId AND e.kind = ?
                        WHERE s.depth < 50
                    )
                    SELECT viewId FROM subtree
                    """, arguments: [rootId, EdgeKind.composesView.rawValue])
                subtreeViewIds = Set(descendants.map { $0["viewId"] as Int64 })
            } else {
                subtreeViewIds = nil
            }

            // Get all @Environment usages: view → keyPath
            let usages = try Row.fetchAll(db, sql: """
                SELECT
                    parentEdge.sourceId AS viewId,
                    viewSym.name AS viewName,
                    viewSym.filePath AS viewFile,
                    viewSym.line AS viewLine,
                    wu.argument AS keyPath
                FROM wrapper_usage wu
                JOIN edges parentEdge ON parentEdge.targetId = wu.symbolId
                    AND parentEdge.kind = ?
                JOIN symbols viewSym ON parentEdge.sourceId = viewSym.id
                WHERE wu.projectId = ?
                    AND wu.wrapperName = 'Environment'
                    AND wu.argument IS NOT NULL
                """, arguments: [EdgeKind.contains.rawValue, projectId])
                .filter { row in
                    // Exclude system-provided environment keys
                    let keyPath: String = row["keyPath"]
                    if Self.systemEnvironmentKeys.contains(keyPath) { return false }
                    // Filter to subtree if rootView was specified
                    if let subtreeViewIds {
                        let viewId: Int64 = row["viewId"]
                        return subtreeViewIds.contains(viewId)
                    }
                    return true
                }

            var results: [EnvironmentInjectionCheck] = []

            for usage in usages {
                let viewId: Int64 = usage["viewId"]
                let viewName: String = usage["viewName"]
                let viewFile: String? = usage["viewFile"]
                let viewLine: Int? = usage["viewLine"]
                let keyPath: String = usage["keyPath"]

                // Walk UP the view tree to find an ancestor that injects this keyPath
                let provider = try Row.fetchOne(db, sql: """
                    WITH RECURSIVE ancestors(viewId, depth) AS (
                        SELECT ?, 0

                        UNION ALL

                        SELECT e.sourceId, a.depth + 1
                        FROM ancestors a
                        JOIN edges e ON e.targetId = a.viewId AND e.kind = ?
                        WHERE a.depth < 20
                    )
                    SELECT s.name AS providerName, a.depth
                    FROM ancestors a
                    JOIN environment_injections ei ON ei.viewSymbolId = a.viewId
                        AND ei.keyPath = ?
                    JOIN symbols s ON a.viewId = s.id
                    WHERE a.depth > 0
                    ORDER BY a.depth
                    LIMIT 1
                    """, arguments: [viewId, EdgeKind.composesView.rawValue, keyPath])

                let providerName: String? = provider?["providerName"]
                let keyName = keyPath.hasPrefix("\\.") ? String(keyPath.dropFirst(2)) : keyPath

                results.append(EnvironmentInjectionCheck(
                    viewName: viewName,
                    viewFile: viewFile,
                    viewLine: viewLine,
                    keyName: keyName,
                    keyPath: keyPath,
                    status: providerName != nil ? .provided : .missing,
                    injectedBy: providerName
                ))
            }

            return results.sorted { a, b in
                if a.status != b.status { return a.status == .missing }
                return a.viewName < b.viewName
            }
        }
    }

    // MARK: - audit_access_control

    /// Find symbols with overly broad access control.
    public func auditAccessControl(
        projectId: Int64,
        module: String? = nil,
        kind: NodeKind? = nil
    ) throws -> [AccessControlIssue] {
        try db.dbWriter.read { db in
            var sql = """
                SELECT s.id, s.name, s.kind, s.qualifiedName, s.filePath, s.line,
                       s.accessLevel, m.name AS moduleName
                FROM symbols s
                LEFT JOIN modules m ON s.moduleId = m.id
                WHERE s.projectId = ?
                  AND s.accessLevel IN ('public', 'open', 'internal')
                  AND s.kind IN ('struct', 'class', 'enum', 'actor', 'protocol', 'function', 'variable', 'typeAlias')
                  AND s.qualifiedName NOT LIKE 'unresolved:%'
                  AND s.qualifiedName NOT LIKE 'file:%'
                  AND s.qualifiedName NOT LIKE 'module:%'
                  AND (s.filePath IS NULL OR (s.filePath NOT LIKE '%/Tests/%' AND s.filePath NOT LIKE '%Tests.swift'))
                  AND NOT EXISTS (
                      SELECT 1 FROM edges e2
                      WHERE e2.sourceId = s.id
                      AND e2.kind = 'implementsRequirement'
                  )
                """
            var arguments: [any DatabaseValueConvertible] = [projectId]

            if let module {
                sql += " AND m.name = ?"
                arguments.append(module)
            }
            if let kind {
                sql += " AND s.kind = ?"
                arguments.append(kind.rawValue)
            }

            sql += " ORDER BY s.accessLevel, s.kind, s.name"

            let symbols = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            var issues: [AccessControlIssue] = []

            for row in symbols {
                let symbolId: Int64 = row["id"]
                let symbolFile: String? = row["filePath"]
                let access: String = row["accessLevel"]

                guard let symbolFile else { continue }

                // Get all incoming edge sources (files that reference this symbol)
                let referencingFiles = try Set(Row.fetchAll(db, sql: """
                    SELECT DISTINCT s.filePath
                    FROM edges e
                    JOIN symbols s ON e.sourceId = s.id
                    WHERE e.targetId = ?
                    AND e.kind NOT IN ('contains', 'extends')
                    AND s.filePath IS NOT NULL
                    """, arguments: [symbolId])
                    .compactMap { (row: Row) -> String? in
                        row["filePath"]
                    })

                if access == "public" || access == "open" {
                    if referencingFiles.isEmpty {
                        // Public but nothing references it at all
                        issues.append(AccessControlIssue(
                            name: row["name"],
                            kind: row["kind"],
                            currentAccess: access,
                            suggestedAccess: "internal or private",
                            reason: "No external references found",
                            filePath: symbolFile,
                            line: row["line"],
                            moduleName: row["moduleName"]
                        ))
                    } else if referencingFiles.allSatisfy({ $0 == symbolFile }) {
                        // Public but only referenced from same file
                        issues.append(AccessControlIssue(
                            name: row["name"],
                            kind: row["kind"],
                            currentAccess: access,
                            suggestedAccess: "fileprivate or private",
                            reason: "Only referenced within same file",
                            filePath: symbolFile,
                            line: row["line"],
                            moduleName: row["moduleName"]
                        ))
                    }
                } else if access == "internal" {
                    if referencingFiles.isEmpty || referencingFiles.allSatisfy({ $0 == symbolFile }) {
                        issues.append(AccessControlIssue(
                            name: row["name"],
                            kind: row["kind"],
                            currentAccess: access,
                            suggestedAccess: "private or fileprivate",
                            reason: referencingFiles.isEmpty
                                ? "No external references found"
                                : "Only referenced within same file",
                            filePath: symbolFile,
                            line: row["line"],
                            moduleName: row["moduleName"]
                        ))
                    }
                }
            }

            return issues
        }
    }

    // MARK: - module_api

    /// List the public API surface of a module — all public/open types and their public members.
    public func moduleApi(
        projectId: Int64,
        module: String,
        accessLevel: String = "public",
        kind: NodeKind? = nil
    ) throws -> ModuleApiResult {
        try db.dbWriter.read { db in
            let accessLevels: [String]
            switch accessLevel {
            case "public": accessLevels = ["public", "open"]
            case "internal": accessLevels = ["public", "open", "internal"]
            case "all": accessLevels = ["public", "open", "internal", "fileprivate", "private"]
            default: accessLevels = ["public", "open"]
            }

            let placeholders = accessLevels.map { _ in "?" }.joined(separator: ", ")

            var sql = """
                SELECT s.id, s.name, s.qualifiedName, s.kind, s.accessLevel,
                       s.signature, s.filePath, s.line
                FROM symbols s
                JOIN modules m ON s.moduleId = m.id
                WHERE s.projectId = ?
                  AND m.name = ?
                  AND s.accessLevel IN (\(placeholders))
                  AND s.kind IN ('struct', 'class', 'enum', 'actor', 'protocol', 'function', 'variable', 'typeAlias')
                  AND s.qualifiedName NOT LIKE 'unresolved:%'
                  AND s.qualifiedName NOT LIKE 'file:%'
                """
            var arguments: [any DatabaseValueConvertible] = [projectId, module] + accessLevels

            if let kind {
                sql += " AND s.kind = ?"
                arguments.append(kind.rawValue)
            }

            sql += " ORDER BY s.kind, s.name"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            var types: [ModuleApiEntry] = []
            var functions: [ModuleApiEntry] = []
            var variables: [ModuleApiEntry] = []

            for row in rows {
                let symbolId: Int64 = row["id"]
                let symbolKind: String = row["kind"]

                // Fetch public members for type symbols
                var members: [ModuleApiMember] = []
                let isType = ["struct", "class", "enum", "actor", "protocol"].contains(symbolKind)
                if isType {
                    let memberRows = try Row.fetchAll(db, sql: """
                        SELECT s2.name, s2.kind, s2.accessLevel, s2.signature
                        FROM edges e
                        JOIN symbols s2 ON e.targetId = s2.id
                        WHERE e.sourceId = ?
                          AND e.kind = 'contains'
                          AND s2.kind IN ('function', 'variable', 'initializer', 'typeAlias', 'enum', 'struct')
                          AND (s2.accessLevel IN (\(placeholders)) OR s2.accessLevel IS NULL)
                        ORDER BY s2.kind, s2.name
                        """, arguments: StatementArguments([symbolId] + accessLevels.map { $0 as any DatabaseValueConvertible }))

                    members = memberRows.map { mRow in
                        ModuleApiMember(
                            name: mRow["name"],
                            kind: mRow["kind"],
                            accessLevel: mRow["accessLevel"],
                            signature: mRow["signature"]
                        )
                    }
                }

                let entry = ModuleApiEntry(
                    name: row["name"],
                    qualifiedName: row["qualifiedName"],
                    kind: symbolKind,
                    accessLevel: row["accessLevel"],
                    signature: row["signature"],
                    filePath: row["filePath"],
                    line: row["line"],
                    members: members
                )

                switch symbolKind {
                case "function": functions.append(entry)
                case "variable": variables.append(entry)
                default: types.append(entry)
                }
            }

            return ModuleApiResult(
                moduleName: module,
                types: types,
                functions: functions,
                variables: variables
            )
        }
    }

    // MARK: - cross_module_usage

    /// Find which specific types from other modules a given module uses.
    public func crossModuleUsage(
        projectId: Int64,
        module: String,
        targetModule: String? = nil
    ) throws -> CrossModuleResult {
        try db.dbWriter.read { db in
            // Find all type references originating from the source module,
            // resolving modules via moduleId or file path fallback.
            let rows = try Row.fetchAll(db, sql: """
                SELECT tr.referencedTypeName,
                       target_sym.kind AS targetKind,
                       target_sym.filePath AS targetFile,
                       target_sym.line AS targetLine,
                       COALESCE(tm.name, tmf.name) AS targetModule,
                       COUNT(*) AS usageCount
                FROM type_references tr
                JOIN symbols src ON src.id = tr.sourceSymbolId
                LEFT JOIN modules sm ON sm.id = src.moduleId
                LEFT JOIN modules smf ON smf.projectId = src.projectId
                    AND src.moduleId IS NULL AND smf.path IS NOT NULL
                    AND src.filePath LIKE '%/' || smf.path || '/%'
                JOIN symbols target_sym ON target_sym.projectId = tr.projectId
                    AND target_sym.name = tr.referencedTypeName
                    AND target_sym.kind IN ('struct', 'class', 'enum', 'protocol', 'actor', 'typeAlias')
                    AND target_sym.qualifiedName NOT LIKE 'unresolved:%'
                LEFT JOIN modules tm ON tm.id = target_sym.moduleId
                LEFT JOIN modules tmf ON tmf.projectId = target_sym.projectId
                    AND target_sym.moduleId IS NULL AND tmf.path IS NOT NULL
                    AND target_sym.filePath LIKE '%/' || tmf.path || '/%'
                WHERE tr.projectId = ?
                    AND COALESCE(sm.name, smf.name) = ?
                    AND COALESCE(tm.name, tmf.name) IS NOT NULL
                    AND COALESCE(tm.name, tmf.name) != COALESCE(sm.name, smf.name)
                GROUP BY tr.referencedTypeName, target_sym.kind,
                         COALESCE(tm.name, tmf.name)
                ORDER BY COALESCE(tm.name, tmf.name), usageCount DESC
                """, arguments: [projectId, module])

            var byModule: [String: [CrossModuleEntry]] = [:]
            for row in rows {
                let targetMod: String = row["targetModule"]
                if let filter = targetModule, targetMod != filter { continue }
                let entry = CrossModuleEntry(
                    typeName: row["referencedTypeName"],
                    kind: row["targetKind"],
                    filePath: row["targetFile"],
                    line: row["targetLine"],
                    usageCount: row["usageCount"]
                )
                byModule[targetMod, default: []].append(entry)
            }

            let modules = byModule.map { (name, entries) in
                CrossModuleDependency(moduleName: name, types: entries)
            }.sorted { $0.types.count > $1.types.count }

            let totalTypes = modules.reduce(0) { $0 + $1.types.count }
            return CrossModuleResult(
                sourceModule: module,
                totalCrossModuleTypes: totalTypes,
                dependencies: modules
            )
        }
    }

    // MARK: - test_coverage

    /// Find which production types have tests and which don't.
    /// Uses naming conventions (FooTests → Foo) and type reference analysis.
    public func testCoverage(
        projectId: Int64,
        module: String? = nil
    ) throws -> TestCoverageResult {
        try db.dbWriter.read { db in
            // 1. Find test classes by module kind or file path heuristic
            let testClassRows = try Row.fetchAll(db, sql: """
                SELECT s.name, s.inheritedTypes, s.attributes
                FROM symbols s
                WHERE s.projectId = ?
                    AND s.kind IN ('struct', 'class')
                    AND s.qualifiedName NOT LIKE 'unresolved:%'
                    AND (
                        s.moduleId IN (SELECT id FROM modules WHERE projectId = ? AND kind = 'test')
                        OR s.filePath LIKE '%/Tests/%'
                    )
                """, arguments: [projectId, projectId])

            // Build naming convention map: production name → test class name
            var testedByNaming: [String: String] = [:]
            for row in testClassRows {
                let name: String = row["name"]
                // FooTests → Foo
                if name.hasSuffix("Tests") {
                    let productionName = String(name.dropLast(5))
                    if !productionName.isEmpty {
                        testedByNaming[productionName] = name
                    }
                } else if name.hasSuffix("Test") {
                    let productionName = String(name.dropLast(4))
                    if !productionName.isEmpty {
                        testedByNaming[productionName] = name
                    }
                } else if name.hasSuffix("Spec") {
                    let productionName = String(name.dropLast(4))
                    if !productionName.isEmpty {
                        testedByNaming[productionName] = name
                    }
                }
            }

            // 2. Find all type names referenced from test files
            let refRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT tr.referencedTypeName
                FROM type_references tr
                WHERE tr.projectId = ?
                    AND (
                        EXISTS (
                            SELECT 1 FROM symbols s
                            WHERE s.id = tr.sourceSymbolId
                            AND (
                                s.moduleId IN (SELECT id FROM modules WHERE projectId = ? AND kind = 'test')
                                OR s.filePath LIKE '%/Tests/%'
                            )
                        )
                        OR tr.filePath LIKE '%/Tests/%'
                    )
                """, arguments: [projectId, projectId])

            var referencedFromTests: Set<String> = []
            for row in refRows {
                let name: String = row["referencedTypeName"]
                referencedFromTests.insert(name)
            }

            // 3. Get all production types (not in test targets, not members, not CodingKeys)
            // JOIN modules via moduleId when available, else fall back to file path matching
            var sql = """
                SELECT s.id, s.name, s.qualifiedName, s.kind, s.filePath, s.line,
                       s.accessLevel, s.inheritedTypes,
                       COALESCE(m.name, mf.name) AS moduleName
                FROM symbols s
                LEFT JOIN modules m ON s.moduleId = m.id
                LEFT JOIN modules mf ON mf.projectId = s.projectId
                    AND s.moduleId IS NULL
                    AND mf.path IS NOT NULL
                    AND s.filePath LIKE '%/' || mf.path || '/%'
                WHERE s.projectId = ?
                    AND s.kind IN ('struct', 'class', 'enum', 'protocol', 'actor')
                    AND s.qualifiedName NOT LIKE 'unresolved:%'
                    AND s.name != 'CodingKeys'
                    AND (s.moduleId IS NULL OR s.moduleId NOT IN (
                        SELECT id FROM modules WHERE projectId = ? AND kind = 'test'
                    ))
                    AND (s.filePath IS NULL OR s.filePath NOT LIKE '%/Tests/%')
                """
            var arguments: [any DatabaseValueConvertible] = [projectId, projectId]

            if let module {
                sql += " AND COALESCE(m.name, mf.name) = ?"
                arguments.append(module)
            }

            sql += " ORDER BY s.name"

            let productionRows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            var tested: [TestCoverageEntry] = []
            var untested: [TestCoverageEntry] = []

            for row in productionRows {
                let name: String = row["name"]
                let kind: String = row["kind"]
                let filePath: String? = row["filePath"]
                let line: Int? = row["line"]
                let moduleName: String? = row["moduleName"]
                let inheritedJSON: String? = row["inheritedTypes"]

                // Detect View conformers
                let isView: Bool
                if let json = inheritedJSON {
                    isView = json.contains("\"View\"")
                } else {
                    isView = false
                }

                let testClassName = testedByNaming[name]
                let isReferencedByTest = referencedFromTests.contains(name)

                let entry = TestCoverageEntry(
                    name: name,
                    kind: kind,
                    filePath: filePath,
                    line: line,
                    moduleName: moduleName,
                    testedBy: testClassName ?? (isReferencedByTest ? "(referenced)" : nil),
                    isView: isView
                )

                if testClassName != nil || isReferencedByTest {
                    tested.append(entry)
                } else {
                    untested.append(entry)
                }
            }

            let total = tested.count + untested.count
            let coveragePercent = total > 0 ? Double(tested.count) / Double(total) * 100.0 : 0.0

            // Compute logic-only coverage (excluding View types)
            let logicTested = tested.filter { !$0.isView }
            let logicUntested = untested.filter { !$0.isView }
            let logicTotal = logicTested.count + logicUntested.count
            let logicCoveragePercent = logicTotal > 0
                ? Double(logicTested.count) / Double(logicTotal) * 100.0 : 0.0

            let viewCount = tested.filter(\.isView).count + untested.filter(\.isView).count

            return TestCoverageResult(
                totalProductionTypes: total,
                testedCount: tested.count,
                untestedCount: untested.count,
                coveragePercent: coveragePercent,
                logicTypes: logicTotal,
                logicTestedCount: logicTested.count,
                logicCoveragePercent: logicCoveragePercent,
                viewTypes: viewCount,
                untested: untested,
                tested: tested
            )
        }
    }

    // MARK: - Helpers

    private func ftsQuery(_ query: String) -> String {
        // Convert user query to FTS5 query with prefix matching.
        // Split on non-identifier characters so qualified names, signatures, etc. work.
        // Strip FTS5 special chars (", (, ), :, *, ^, +, -, ~) to prevent syntax errors.
        let terms = query
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")
        return terms.isEmpty ? "a*" : terms
    }

    private func buildViewTree(from rows: [Row], rootName: String) -> ViewTreeNode {
        guard let rootRow = rows.first else {
            return ViewTreeNode(name: rootName, filePath: nil, line: nil, context: nil, children: [])
        }

        // Collect node data and parent→children mapping
        struct NodeData {
            let name: String
            let filePath: String?
            let line: Int?
            let context: String?
        }

        var nodeData: [Int64: NodeData] = [:]
        var childrenOf: [Int64: [Int64]] = [:]
        var seen = Set<Int64>()

        for row in rows {
            let id: Int64 = row["id"]
            guard seen.insert(id).inserted else { continue }

            nodeData[id] = NodeData(
                name: row["name"],
                filePath: row["filePath"],
                line: row["line"],
                context: row["context"]
            )

            let parentId: Int64? = row["parentId"]
            if let parentId {
                childrenOf[parentId, default: []].append(id)
            }
        }

        // Recursively build the tree
        let rootId: Int64 = rootRow["id"]
        func buildNode(_ id: Int64) -> ViewTreeNode {
            let data = nodeData[id]!
            let children = (childrenOf[id] ?? []).map { buildNode($0) }
            return ViewTreeNode(
                name: data.name,
                filePath: data.filePath,
                line: data.line,
                context: data.context,
                children: children
            )
        }

        return buildNode(rootId)
    }

    private func buildImpactTree(from rows: [Row], rootName: String) -> ImpactNode {
        guard let rootRow = rows.first else {
            return ImpactNode(name: rootName, kind: "unknown", filePath: nil, line: nil, edgeKind: nil, children: [])
        }

        struct NodeData {
            let name: String
            let kind: String
            let filePath: String?
            let line: Int?
            let edgeKind: String?
        }

        var nodeData: [Int64: NodeData] = [:]
        var childrenOf: [Int64: [Int64]] = [:]
        var seen = Set<Int64>()

        for row in rows {
            let id: Int64 = row["id"]
            guard seen.insert(id).inserted else { continue }

            nodeData[id] = NodeData(
                name: row["name"],
                kind: row["kind"],
                filePath: row["filePath"],
                line: row["line"],
                edgeKind: row["edgeKind"]
            )

            let parentId: Int64? = row["parentId"]
            if let parentId {
                childrenOf[parentId, default: []].append(id)
            }
        }

        let rootId: Int64 = rootRow["id"]
        func buildNode(_ id: Int64) -> ImpactNode {
            let data = nodeData[id]!
            let children = (childrenOf[id] ?? []).map { buildNode($0) }
            return ImpactNode(
                name: data.name,
                kind: data.kind,
                filePath: data.filePath,
                line: data.line,
                edgeKind: data.edgeKind,
                children: children
            )
        }

        return buildNode(rootId)
    }

    private static func symbolFromRow(_ row: Row) -> MemberInfo {
        MemberInfo(
            name: row["name"],
            kind: row["kind"],
            line: row["line"],
            accessLevel: row["accessLevel"],
            signature: row["signature"]
        )
    }
}

// MARK: - Query Result Types

public struct SymbolSearchResult: Sendable {
    public let id: Int64
    public let name: String
    public let qualifiedName: String
    public let kind: String
    public let moduleName: String?
    public let filePath: String?
    public let line: Int?
    public let accessLevel: String?
    public let signature: String?
}

public struct SymbolDetail: Sendable {
    public let symbol: SymbolRecord
    public let moduleName: String?
    public let members: [MemberInfo]
    public let conformances: [RelatedType]
    public let extensions: [MemberInfo]
    public let wrapperUsages: [WrapperUsageRecord]
}

public struct MemberInfo: Sendable {
    public let name: String
    public let kind: String
    public let line: Int?
    public let accessLevel: String?
    public let signature: String?
}

public struct RelatedType: Sendable {
    public let name: String
    public let relationship: String // "conformsTo" or "inherits"
}

public struct ModuleGraph: Sendable {
    public let modules: [ModuleInfo]
}

public struct ModuleInfo: Sendable {
    public let name: String
    public let kind: String
    public let path: String?
    public var dependencies: [String]
}

public struct ViewTreeNode: Sendable {
    public let name: String
    public let filePath: String?
    public let line: Int?
    public let context: String?
    public let children: [ViewTreeNode]
}

public struct ExtensionInfo: Sendable {
    public let filePath: String?
    public let line: Int?
    public let conformances: [String]
    public let members: [String]
}

public enum DependencyDirection: Sendable {
    case incoming
    case outgoing
    case both
}

public struct DependencyResult: Sendable {
    public let symbolName: String
    public let dependsOn: [DependencyInfo]
    public let dependedOnBy: [DependencyInfo]
}

public struct DependencyInfo: Sendable {
    public let name: String
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let relationship: String
}

public struct ArchitectureOverview: Sendable {
    public let modules: [ModuleInfo]
    public let protocolCount: Int
    public let protocolStats: [ProtocolStat]
    public let viewModels: [ViewModelInfo]
    public let environmentKeys: [EnvironmentKeyInfo]
    public let fileCount: Int
    public let totalSymbols: Int
}

public struct ProtocolStat: Sendable {
    public let name: String
    public let conformerCount: Int
}

public struct ViewModelInfo: Sendable {
    public let name: String
    public let filePath: String?
    public let line: Int?
}

public struct EnvironmentKeyInfo: Sendable {
    public let keyName: String
    public let valueType: String?
    public let filePath: String?
    public let line: Int?
}

// MARK: - Dead Code Types

public struct DeadCodeEntry: Sendable {
    public let name: String
    public let kind: String
    public let qualifiedName: String
    public let filePath: String?
    public let line: Int?
    public let moduleName: String?
    public let referenceCount: Int
}

// MARK: - Protocol Coverage Types

public struct ProtocolCoverageResult: Sendable {
    public let protocolName: String
    public let requirements: [ProtocolRequirement]
    public let conformers: [ConformerCoverage]
}

public struct ProtocolRequirement: Sendable {
    public let name: String
    public let kind: String
    public let signature: String?
}

public struct ConformerCoverage: Sendable {
    public let name: String
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let satisfied: [String]
    public let missing: [String]
}

// MARK: - Impact Analysis Types

public struct ImpactNode: Sendable {
    public let name: String
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let edgeKind: String?
    public let children: [ImpactNode]
}

// MARK: - Call Graph Types

public struct CallGraphResult: Sendable {
    public let functionName: String
    public let kind: String
    public let parentType: String?
    public let filePath: String?
    public let line: Int?
    public let callers: [CallGraphNode]
    public let callees: [CallGraphNode]
}

public struct CallGraphNode: Sendable {
    public let name: String        // Qualified: ParentType.methodName
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let depth: Int
    public let callKind: String?   // selfCall, staticCall, etc.
}

// MARK: - Environment Injection Check Types

public enum InjectionStatus: Sendable {
    case provided
    case missing
}

public struct EnvironmentInjectionCheck: Sendable {
    public let viewName: String
    public let viewFile: String?
    public let viewLine: Int?
    public let keyName: String
    public let keyPath: String
    public let status: InjectionStatus
    public let injectedBy: String?
}

// MARK: - Source Context Helper

/// Read lines from a file with context around a target line.
public func readSourceContext(filePath: String, line: Int, contextLines: Int) -> String? {
    guard FileManager.default.fileExists(atPath: filePath) else { return nil }
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
    let allLines = content.components(separatedBy: "\n")
    let start = max(1, line - contextLines)
    let end = min(allLines.count, line + contextLines)
    guard start <= end else { return nil }
    return allLines[(start - 1)..<end].enumerated().map { offset, text in
        let lineNum = start + offset
        let marker = lineNum == line ? ">" : " "
        return String(format: "%@%4d | %@", marker, lineNum, text)
    }.joined(separator: "\n")
}

// MARK: - Read Symbol Result

public struct ReadSymbolResult: Sendable {
    public let symbolName: String
    public let kind: String?
    public let qualifiedName: String?
    public let filePath: String?
    public let startLine: Int?
    public let endLine: Int?
    public let source: String?          // Numbered source lines
    public let suggestions: [String]?   // Set when symbol not found
    public let stale: Bool              // True when file changed since last index
}

// MARK: - Usage Result Types

public struct UsageResult: Sendable {
    public let symbolName: String
    public let symbolKind: String
    public let usages: [UsageSite]
    public let parentTypeName: String? // set when showing parent type refs for a member
    public var suggestions: [String]? // set when symbol not found, with similar names
}

public struct UsageSite: Sendable {
    public let filePath: String?
    public let line: Int?
    public let usedBy: String       // enclosing type/symbol name
    public let usedByKind: String   // kind of the enclosing symbol
    public let context: String      // "type reference", "conformsTo", "composesView", etc.
}

// MARK: - Access Control Audit Types

public struct AccessControlIssue: Sendable {
    public let name: String
    public let kind: String
    public let currentAccess: String
    public let suggestedAccess: String
    public let reason: String
    public let filePath: String?
    public let line: Int?
    public let moduleName: String?
}

// MARK: - Module API Types

public struct ModuleApiResult: Sendable {
    public let moduleName: String
    public let types: [ModuleApiEntry]
    public let functions: [ModuleApiEntry]
    public let variables: [ModuleApiEntry]
}

public struct ModuleApiEntry: Sendable {
    public let name: String
    public let qualifiedName: String
    public let kind: String
    public let accessLevel: String
    public let signature: String?
    public let filePath: String?
    public let line: Int?
    public let members: [ModuleApiMember]
}

public struct ModuleApiMember: Sendable {
    public let name: String
    public let kind: String
    public let accessLevel: String?
    public let signature: String?
}

// MARK: - Diff Since Types

public struct SymbolChange: Sendable {
    public let name: String
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let detail: String?

    public init(name: String, kind: String, filePath: String?, line: Int?, detail: String?) {
        self.name = name
        self.kind = kind
        self.filePath = filePath
        self.line = line
        self.detail = detail
    }
}

// MARK: - Test Coverage Types

public struct TestCoverageResult: Sendable {
    public let totalProductionTypes: Int
    public let testedCount: Int
    public let untestedCount: Int
    public let coveragePercent: Double
    public let logicTypes: Int
    public let logicTestedCount: Int
    public let logicCoveragePercent: Double
    public let viewTypes: Int
    public let untested: [TestCoverageEntry]
    public let tested: [TestCoverageEntry]
}

public struct TestCoverageEntry: Sendable {
    public let name: String
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let moduleName: String?
    public let testedBy: String? // test class name, or "(referenced)" for ref-only
    public let isView: Bool
}

// MARK: - Cross-Module Usage Types

public struct CrossModuleResult: Sendable {
    public let sourceModule: String
    public let totalCrossModuleTypes: Int
    public let dependencies: [CrossModuleDependency]
}

public struct CrossModuleDependency: Sendable {
    public let moduleName: String
    public let types: [CrossModuleEntry]
}

public struct CrossModuleEntry: Sendable {
    public let typeName: String
    public let kind: String
    public let filePath: String?
    public let line: Int?
    public let usageCount: Int
}
