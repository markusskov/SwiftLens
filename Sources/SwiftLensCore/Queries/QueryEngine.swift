import GRDB
import Foundation

/// Central query engine providing all MCP tool implementations.
public struct QueryEngine: Sendable {
    private let db: GraphDatabase

    public init(db: GraphDatabase) {
        self.db = db
    }

    // MARK: - search_symbol

    /// FTS5 search for symbols by name.
    public func searchSymbol(
        projectId: Int64,
        query: String,
        kind: NodeKind? = nil,
        module: String? = nil,
        limit: Int = 20
    ) throws -> [SymbolSearchResult] {
        try db.dbWriter.read { db in
            var sql = """
                SELECT s.*, m.name AS moduleName
                FROM symbols s
                JOIN symbols_fts ON symbols_fts.rowid = s.rowid
                LEFT JOIN modules m ON s.moduleId = m.id
                WHERE symbols_fts MATCH ?
                AND s.projectId = ?
                """
            var arguments: [any DatabaseValueConvertible] = [ftsQuery(query), projectId]

            if let kind {
                sql += " AND s.kind = ?"
                arguments.append(kind.rawValue)
            }

            if let module {
                sql += " AND m.name = ?"
                arguments.append(module)
            }

            sql += " ORDER BY rank LIMIT ?"
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
                return ViewTreeNode(name: rootView, filePath: nil, line: nil, children: [])
            }

            // Recursive CTE for view tree
            let rows = try Row.fetchAll(db, sql: """
                WITH RECURSIVE view_tree(id, name, filePath, line, depth) AS (
                    SELECT s.id, s.name, s.filePath, s.line, 0
                    FROM symbols s
                    WHERE s.id = ?

                    UNION ALL

                    SELECT child.id, child.name, child.filePath, child.line, vt.depth + 1
                    FROM view_tree vt
                    JOIN edges e ON e.sourceId = vt.id AND e.kind = ?
                    JOIN symbols child ON e.targetId = child.id
                    WHERE vt.depth < ?
                )
                SELECT DISTINCT id, name, filePath, line, depth FROM view_tree
                ORDER BY depth, name
                """, arguments: [root.id, EdgeKind.composesView.rawValue, maxDepth])

            // Build tree from flat rows
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

            // View models (classes/structs with @Observable or names ending in ViewModel)
            let viewModels = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(
                    Column("name").like("%ViewModel") ||
                    Column("attributes").like("%@Observable%")
                )
                .filter(Column("kind") != NodeKind.extension.rawValue)
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

    // MARK: - Helpers

    private func ftsQuery(_ query: String) -> String {
        // Convert user query to FTS5 query with prefix matching
        let terms = query.split(separator: " ")
            .map { "\($0)*" }
            .joined(separator: " ")
        return terms.isEmpty ? "*" : terms
    }

    private func buildViewTree(from rows: [Row], rootName: String) -> ViewTreeNode {
        guard let rootRow = rows.first else {
            return ViewTreeNode(name: rootName, filePath: nil, line: nil, children: [])
        }

        // Group by depth, build tree
        var nodeMap: [Int64: ViewTreeNode] = [:]

        let rootId: Int64 = rootRow["id"]
        nodeMap[rootId] = ViewTreeNode(
            name: rootRow["name"],
            filePath: rootRow["filePath"],
            line: rootRow["line"],
            children: []
        )

        // This is simplified — for a proper tree we'd need parent tracking in the CTE
        // For now, return a flat list grouped by depth
        var children: [ViewTreeNode] = []
        for row in rows.dropFirst() {
            let id: Int64 = row["id"]
            guard nodeMap[id] == nil else { continue } // Skip duplicates
            let node = ViewTreeNode(
                name: row["name"],
                filePath: row["filePath"],
                line: row["line"],
                children: []
            )
            nodeMap[id] = node
            children.append(node)
        }

        return ViewTreeNode(
            name: rootRow["name"],
            filePath: rootRow["filePath"],
            line: rootRow["line"],
            children: children
        )
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
