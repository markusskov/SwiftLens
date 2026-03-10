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

            // Exclude unresolved placeholder symbols
            sql += " AND s.qualifiedName NOT LIKE 'unresolved:%'"

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

            // Recursive CTE with parent tracking for proper tree reconstruction
            let rows = try Row.fetchAll(db, sql: """
                WITH RECURSIVE view_tree(id, name, filePath, line, depth, parentId) AS (
                    SELECT s.id, s.name, s.filePath, s.line, 0, CAST(NULL AS INTEGER)
                    FROM symbols s
                    WHERE s.id = ?

                    UNION ALL

                    SELECT child.id, child.name, child.filePath, child.line, vt.depth + 1, vt.id
                    FROM view_tree vt
                    JOIN edges e ON e.sourceId = vt.id AND e.kind = ?
                    JOIN symbols child ON e.targetId = child.id
                    WHERE vt.depth < ?
                )
                SELECT DISTINCT id, name, filePath, line, depth, parentId FROM view_tree
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

    /// Find symbols with zero incoming usage edges — potential dead code.
    public func findDeadCode(
        projectId: Int64,
        module: String? = nil
    ) throws -> [DeadCodeEntry] {
        try db.dbWriter.read { db in
            var sql = """
                SELECT s.id, s.name, s.kind, s.qualifiedName, s.filePath, s.line, m.name AS moduleName
                FROM symbols s
                LEFT JOIN modules m ON s.moduleId = m.id
                WHERE s.projectId = ?
                  AND s.kind IN ('struct', 'class', 'enum', 'actor', 'function', 'typeAlias')
                  AND s.qualifiedName NOT LIKE 'unresolved:%'
                  AND s.qualifiedName NOT LIKE 'file:%'
                  AND s.qualifiedName NOT LIKE 'module:%'
                  -- Top-level only: not a member of another type
                  AND NOT EXISTS (
                    SELECT 1 FROM edges ce WHERE ce.targetId = s.id AND ce.kind = 'contains'
                  )
                  -- No usage edges (exclude extends which is structural, not usage)
                  AND NOT EXISTS (
                    SELECT 1 FROM edges ue
                    WHERE ue.targetId = s.id
                    AND ue.kind NOT IN ('extends', 'contains')
                  )
                  -- Not @main entry point
                  AND (s.attributes IS NULL OR s.attributes NOT LIKE '%@main%')
                  -- Not in a test target (by module or file path)
                  AND NOT EXISTS (
                    SELECT 1 FROM modules tm
                    WHERE tm.id = s.moduleId AND tm.kind = 'testTarget'
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

            sql += " ORDER BY s.kind, s.name"

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { row in
                    DeadCodeEntry(
                        name: row["name"],
                        kind: row["kind"],
                        qualifiedName: row["qualifiedName"],
                        filePath: row["filePath"],
                        line: row["line"],
                        moduleName: row["moduleName"]
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
    public func checkEnvironmentInjection(
        projectId: Int64
    ) throws -> [EnvironmentInjectionCheck] {
        try db.dbWriter.read { db in
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
                    return !Self.systemEnvironmentKeys.contains(keyPath)
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

        // Collect node data and parent→children mapping
        struct NodeData {
            let name: String
            let filePath: String?
            let line: Int?
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
                line: row["line"]
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
