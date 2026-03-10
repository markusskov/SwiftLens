import Foundation
import GRDB

/// Orchestrates the full indexing pipeline: discovery → hash check → parse → assemble graph.
public actor IndexingCoordinator {
    private let db: GraphDatabase
    private let fileIndexer = SwiftFileIndexer()
    private let fileHasher = FileHasher()

    public init(db: GraphDatabase) {
        self.db = db
    }

    /// Run a full index of a project. Returns the project ID and number of files indexed.
    public func index(
        projectRoot: String,
        name: String? = nil,
        config: ProjectConfig = .default,
        force: Bool = false
    ) async throws -> IndexResult {
        let projectName = name ?? URL(filePath: projectRoot).lastPathComponent

        // Stage 1: File Discovery
        let discovery = FileDiscovery(
            rootPath: projectRoot,
            exclusions: FileDiscovery.defaultExclusions.union(config.exclude),
            additionalPackages: config.packages
        )
        let allFiles = try discovery.discoverFiles()
        let manifests = try discovery.findPackageManifests()

        // Ensure project record exists
        let projectId = try await db.dbWriter.write { db in
            var project = try ProjectRecord.fetchOne(
                db,
                sql: "SELECT * FROM projects WHERE rootPath = ?",
                arguments: [projectRoot]
            ) ?? ProjectRecord(name: projectName, rootPath: projectRoot)
            try project.save(db)
            return project.id!
        }

        // Parse SPM manifests
        let spmParser = SPMManifestParser()
        var allTargets: [SPMTarget] = []
        for manifest in manifests {
            let targets = try spmParser.parse(manifestPath: manifest)
            allTargets.append(contentsOf: targets)
        }

        // Build module records
        let moduleNameToId = try await buildModules(projectId: projectId, targets: allTargets)

        // Build file→module mapping
        let fileModuleMap = buildFileModuleMapping(
            projectRoot: projectRoot,
            targets: allTargets,
            files: allFiles,
            moduleIds: moduleNameToId
        )

        // Stage 2: Incremental Filter
        let (changedFiles, deletedFiles): ([String], [String])
        if force {
            changedFiles = allFiles
            deletedFiles = []
        } else {
            (changedFiles, deletedFiles) = try await filterChangedFiles(
                projectId: projectId,
                files: allFiles
            )
        }

        // Clean up deleted files
        if !deletedFiles.isEmpty {
            try await cleanupDeletedFiles(projectId: projectId, paths: deletedFiles)
        }

        // Stage 3: Parallel Syntax Extraction
        let results = await extractFiles(changedFiles)

        // Stage 4: Graph Assembly
        try await assembleGraph(
            projectId: projectId,
            results: results,
            fileModuleMap: fileModuleMap
        )

        // Update file hashes
        try await updateHashes(projectId: projectId, files: changedFiles)

        // Update project timestamp
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE projects SET lastIndexed = ? WHERE id = ?",
                arguments: [Date(), projectId]
            )
        }

        // Run post-processing
        try await resolveUnresolvedPlaceholders(projectId: projectId)

        let merger = ExtensionMerger(db: db)
        try await merger.merge(projectId: projectId)

        let conformanceResolver = ConformanceResolver(db: db)
        try await conformanceResolver.resolve(projectId: projectId)

        try await resolveEnvironmentEdges(projectId: projectId)

        try await resolveTypeReferences(projectId: projectId)

        try await resolveFunctionCalls(projectId: projectId)

        // Gather post-index stats
        let (totalSymbols, totalEdges) = try await db.dbWriter.read { db in
            let symbols = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM symbols WHERE projectId = ? AND qualifiedName NOT LIKE 'unresolved:%'",
                arguments: [projectId]
            ) ?? 0
            let edges = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM edges WHERE projectId = ?",
                arguments: [projectId]
            ) ?? 0
            return (symbols, edges)
        }

        return IndexResult(
            projectId: projectId,
            totalFiles: allFiles.count,
            indexedFiles: changedFiles.count,
            deletedFiles: deletedFiles.count,
            modules: allTargets.count,
            totalSymbols: totalSymbols,
            totalEdges: totalEdges
        )
    }

    // MARK: - Stage 2: Incremental Filter

    private func filterChangedFiles(
        projectId: Int64,
        files: [String]
    ) async throws -> (changed: [String], deleted: [String]) {
        let storedHashes = try await db.dbWriter.read { db in
            try FileHashRecord
                .filter(Column("projectId") == projectId)
                .fetchAll(db)
        }

        let hashMap = Dictionary(
            storedHashes.map { ($0.filePath, $0.sha256) },
            uniquingKeysWith: { _, last in last }
        )

        var changed: [String] = []
        let fileSet = Set(files)

        for file in files {
            let currentHash = try fileHasher.hash(filePath: file)
            if hashMap[file] != currentHash {
                changed.append(file)
            }
        }

        // Find deleted files
        let deleted = storedHashes
            .map(\.filePath)
            .filter { !fileSet.contains($0) }

        return (changed, deleted)
    }

    // MARK: - Stage 3: Parallel Extraction

    private func extractFiles(_ files: [String]) async -> [FileExtractionResult] {
        await withTaskGroup(of: FileExtractionResult?.self) { group in
            for file in files {
                group.addTask {
                    try? self.fileIndexer.index(filePath: file)
                }
            }

            var results: [FileExtractionResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
    }

    // MARK: - Stage 4: Graph Assembly

    private func assembleGraph(
        projectId: Int64,
        results: [FileExtractionResult],
        fileModuleMap: [String: Int64]
    ) async throws {
        try await db.dbWriter.write { [results] db in
            // Pass 1: Delete old data for ALL changed files first.
            // This prevents cascade issues where processing file B deletes
            // cross-file edges that were just created by file A.
            for result in results {
                try db.execute(
                    sql: "DELETE FROM symbols WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )
                try db.execute(
                    sql: "DELETE FROM wrapper_usage WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )
                try db.execute(
                    sql: "DELETE FROM environment_keys WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )
                try db.execute(
                    sql: "DELETE FROM environment_injections WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )
                try db.execute(
                    sql: "DELETE FROM type_references WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )
                try db.execute(
                    sql: "DELETE FROM function_calls WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )
            }

            // Pass 2: Insert new symbols and edges for all files.
            for result in results {
                let moduleId = fileModuleMap[result.filePath]
                var symbolIds: [String: Int64] = [:] // qualifiedName → id

                for decl in result.declarations {
                    let qualifiedName = Self.buildQualifiedName(
                        decl: decl, filePath: result.filePath
                    )

                    // UPSERT symbol to handle qualified name collisions
                    try db.execute(
                        sql: """
                            INSERT INTO symbols (projectId, moduleId, kind, name, qualifiedName, filePath, line, column, endLine, accessLevel, attributes, modifiers, inheritedTypes, signature, documentation)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT (projectId, qualifiedName) DO UPDATE SET
                                moduleId = excluded.moduleId, kind = excluded.kind,
                                filePath = excluded.filePath, line = excluded.line,
                                column = excluded.column, endLine = excluded.endLine,
                                accessLevel = excluded.accessLevel, attributes = excluded.attributes,
                                modifiers = excluded.modifiers, inheritedTypes = excluded.inheritedTypes,
                                signature = excluded.signature, documentation = excluded.documentation
                            """,
                        arguments: [
                            projectId, moduleId, decl.kind.rawValue, decl.name, qualifiedName,
                            result.filePath, decl.line, decl.column, decl.endLine,
                            decl.accessLevel, Self.encodeJSON(decl.attributes),
                            Self.encodeJSON(decl.modifiers), Self.encodeJSON(decl.inheritedTypes),
                            decl.signature, decl.documentation,
                        ]
                    )
                    let symbolId = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM symbols WHERE projectId = ? AND qualifiedName = ?",
                        arguments: [projectId, qualifiedName]
                    )
                    symbolIds[qualifiedName] = symbolId

                    // Build CONTAINS edges (parent → child)
                    if let parentName = decl.parent, let childId = symbolId {
                        let parentQN = result.declarations
                            .filter { $0.name == parentName && $0.kind != .function && $0.kind != .variable }
                            .first
                            .map { Self.buildQualifiedName(decl: $0, filePath: result.filePath) }

                        if let parentQN, let parentId = symbolIds[parentQN] {
                            var edge = EdgeRecord(
                                projectId: projectId,
                                sourceId: parentId,
                                targetId: childId,
                                kind: EdgeKind.contains.rawValue
                            )
                            try? edge.insert(db) // Ignore duplicates
                        }
                    }

                    // Build CONFORMS_TO and INHERITS edges (deferred to ConformanceResolver for cross-file)
                    // Build EXTENDS edges (deferred to ExtensionMerger)
                }

                // Process imports → file node edges
                for imp in result.imports {
                    // Create a synthetic file symbol if not already present
                    let fileQN = "file:\(result.filePath)"
                    if symbolIds[fileQN] == nil {
                        var fileSym = SymbolRecord(
                            projectId: projectId,
                            moduleId: moduleId,
                            kind: NodeKind.file.rawValue,
                            name: URL(filePath: result.filePath).lastPathComponent,
                            qualifiedName: fileQN,
                            filePath: result.filePath,
                            line: 1,
                            column: 1
                        )
                        try fileSym.insert(db)
                        symbolIds[fileQN] = fileSym.id
                    }

                    // Find or create module symbol
                    let moduleQN = "module:\(imp.moduleName)"
                    var moduleSymId = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM symbols WHERE projectId = ? AND qualifiedName = ?",
                        arguments: [projectId, moduleQN]
                    )

                    if moduleSymId == nil {
                        var moduleSym = SymbolRecord(
                            projectId: projectId,
                            kind: NodeKind.module.rawValue,
                            name: imp.moduleName,
                            qualifiedName: moduleQN,
                            filePath: nil,
                            line: nil,
                            column: nil
                        )
                        try? moduleSym.insert(db)
                        moduleSymId = moduleSym.id ?? (try? Int64.fetchOne(
                            db,
                            sql: "SELECT id FROM symbols WHERE projectId = ? AND qualifiedName = ?",
                            arguments: [projectId, moduleQN]
                        ))
                    }

                    if let fileId = symbolIds[fileQN], let modId = moduleSymId {
                        var edge = EdgeRecord(
                            projectId: projectId,
                            sourceId: fileId,
                            targetId: modId,
                            kind: EdgeKind.imports.rawValue,
                            metadata: imp.isTestable ? "{\"testable\":true}" : nil
                        )
                        try? edge.insert(db) // Ignore duplicates
                    }
                }

                // Process wrapper usages
                for wrapper in result.wrapperUsages {
                    // Find the property symbol
                    let propQN = result.declarations
                        .filter { $0.name == wrapper.propertyName && $0.kind == .variable }
                        .first
                        .map { Self.buildQualifiedName(decl: $0, filePath: result.filePath) }

                    if let propQN, let symbolId = symbolIds[propQN] {
                        var usage = WrapperUsageRecord(
                            projectId: projectId,
                            symbolId: symbolId,
                            wrapperName: wrapper.wrapperName,
                            argument: wrapper.argument,
                            filePath: result.filePath,
                            line: wrapper.line
                        )
                        try usage.insert(db)
                    }
                }

                // Process environment declarations
                for envDecl in result.environmentDeclarations {
                    var envKey = EnvironmentKeyRecord(
                        projectId: projectId,
                        keyName: envDecl.keyName,
                        valueType: envDecl.valueType,
                        filePath: result.filePath,
                        line: envDecl.line
                    )

                    // Find the declaring symbol
                    let declQN = result.declarations
                        .filter { $0.name == envDecl.typeName }
                        .first
                        .map { Self.buildQualifiedName(decl: $0, filePath: result.filePath) }

                    if let declQN, let symbolId = symbolIds[declQN] {
                        envKey.declaringSymbolId = symbolId
                    }

                    // UPSERT
                    try db.execute(
                        sql: """
                            INSERT INTO environment_keys (projectId, keyName, valueType, declaringSymbolId, filePath, line)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT (projectId, keyName) DO UPDATE SET
                                valueType = excluded.valueType,
                                declaringSymbolId = excluded.declaringSymbolId,
                                filePath = excluded.filePath,
                                line = excluded.line
                            """,
                        arguments: [
                            projectId, envKey.keyName, envKey.valueType,
                            envKey.declaringSymbolId, envKey.filePath, envKey.line,
                        ]
                    )
                }

                // Process environment injections (.environment() modifier calls)
                for injection in result.environmentInjections {
                    let viewQN = result.declarations
                        .filter { $0.name == injection.viewName }
                        .first
                        .map { Self.buildQualifiedName(decl: $0, filePath: result.filePath) }

                    if let viewQN, let viewId = symbolIds[viewQN] {
                        var record = EnvironmentInjectionRecord(
                            projectId: projectId,
                            viewSymbolId: viewId,
                            keyPath: injection.keyPath,
                            filePath: result.filePath,
                            line: injection.line
                        )
                        try record.insert(db)
                    }
                }

                // Process type references
                for ref in result.typeReferences {
                    // Find the containing symbol — prefer non-extension declarations
                    let sourceDecl = result.declarations
                        .filter { $0.name == ref.containingSymbol }
                        .sorted { ($0.kind != .extension ? 0 : 1) < ($1.kind != .extension ? 0 : 1) }
                        .first

                    if let sourceDecl {
                        let sourceQN = Self.buildQualifiedName(
                            decl: sourceDecl, filePath: result.filePath
                        )
                        if let sourceId = symbolIds[sourceQN] {
                            var record = TypeReferenceRecord(
                                projectId: projectId,
                                sourceSymbolId: sourceId,
                                referencedTypeName: ref.referencedTypeName,
                                filePath: result.filePath,
                                line: ref.line
                            )
                            try record.insert(db)
                        }
                    }
                }

                // Process function calls
                for call in result.functionCalls {
                    // Find the caller symbol — build qualified name from parent + name
                    let callerQN: String?
                    if let parent = call.callerParent {
                        callerQN = parent + "." + call.callerName
                    } else {
                        let fileName = URL(filePath: result.filePath).lastPathComponent
                        callerQN = fileName + ":" + call.callerName
                    }

                    if let callerQN, let callerId = symbolIds[callerQN] {
                        var record = FunctionCallRecord(
                            projectId: projectId,
                            callerSymbolId: callerId,
                            calleeName: call.calleeName,
                            receiverType: call.receiverType,
                            callKind: call.kind.rawValue,
                            filePath: result.filePath,
                            line: call.line,
                            column: call.column
                        )
                        try record.insert(db)
                    }
                }

                // Process view compositions
                for comp in result.viewCompositions {
                    // Find parent view symbol
                    let parentQN = result.declarations
                        .filter { $0.name == comp.parentView }
                        .first
                        .map { Self.buildQualifiedName(decl: $0, filePath: result.filePath) }

                    guard let parentQN, let parentId = symbolIds[parentQN] else { continue }

                    // Find child view symbol (might be in another file)
                    // Prefer real symbols over unresolved placeholders
                    var childId = try Int64.fetchOne(
                        db,
                        sql: """
                            SELECT id FROM symbols
                            WHERE projectId = ? AND name = ? AND kind IN ('struct', 'class')
                            AND qualifiedName NOT LIKE 'unresolved:%'
                            """,
                        arguments: [projectId, comp.childView]
                    )

                    if childId == nil {
                        // Check for existing placeholder
                        childId = try Int64.fetchOne(
                            db,
                            sql: "SELECT id FROM symbols WHERE projectId = ? AND qualifiedName = ?",
                            arguments: [projectId, "unresolved:" + comp.childView]
                        )
                    }

                    if childId == nil {
                        // Create a placeholder symbol for the child view
                        var placeholder = SymbolRecord(
                            projectId: projectId,
                            kind: NodeKind.struct.rawValue,
                            name: comp.childView,
                            qualifiedName: "unresolved:" + comp.childView
                        )
                        try? placeholder.insert(db)
                        childId = placeholder.id ?? (try? Int64.fetchOne(
                            db,
                            sql: "SELECT id FROM symbols WHERE projectId = ? AND qualifiedName = ?",
                            arguments: [projectId, "unresolved:" + comp.childView]
                        ))
                    }

                    if let childId {
                        var edge = EdgeRecord(
                            projectId: projectId,
                            sourceId: parentId,
                            targetId: childId,
                            kind: EdgeKind.composesView.rawValue,
                            metadata: comp.context
                        )
                        try? edge.insert(db) // Ignore duplicate edge errors
                    }
                }
            }
        }
    }

    // MARK: - Module Building

    @discardableResult
    private func buildModules(projectId: Int64, targets: [SPMTarget]) async throws -> [String: Int64] {
        try await db.dbWriter.write { db in
            // Clear existing modules for this project
            try db.execute(
                sql: "DELETE FROM modules WHERE projectId = ?",
                arguments: [projectId]
            )

            var moduleIds: [String: Int64] = [:]

            // Insert all targets
            for target in targets {
                let resolvedPath = target.path
                    ?? (target.kind == .test ? "Tests/" + target.name : "Sources/" + target.name)
                var module = ModuleRecord(
                    projectId: projectId,
                    name: target.name,
                    path: resolvedPath,
                    kind: target.kind.rawValue
                )
                try module.insert(db)
                moduleIds[target.name] = module.id
            }

            // Insert dependencies
            for target in targets {
                guard let moduleId = moduleIds[target.name] else { continue }
                for dep in target.dependencies {
                    guard let depId = moduleIds[dep] else { continue }
                    var depRecord = ModuleDepRecord(
                        moduleId: moduleId,
                        dependencyId: depId
                    )
                    try depRecord.insert(db)
                }
            }

            return moduleIds
        }
    }

    // MARK: - File→Module Mapping

    private func buildFileModuleMapping(
        projectRoot: String,
        targets: [SPMTarget],
        files: [String],
        moduleIds: [String: Int64]
    ) -> [String: Int64] {
        // Build absolute directory paths for each target
        var targetDirs: [(absoluteDir: String, moduleId: Int64)] = []
        for target in targets {
            guard let moduleId = moduleIds[target.name] else { continue }
            let relPath = target.path ?? Self.defaultTargetPath(for: target)
            let absDir = projectRoot + "/" + relPath + "/"
            targetDirs.append((absDir, moduleId))
        }

        // Sort by path length descending so more specific paths match first
        targetDirs.sort { $0.absoluteDir.count > $1.absoluteDir.count }

        var mapping: [String: Int64] = [:]
        for file in files {
            for (dir, moduleId) in targetDirs {
                if file.hasPrefix(dir) {
                    mapping[file] = moduleId
                    break
                }
            }
        }
        return mapping
    }

    /// Default SPM target directory when no explicit path is specified.
    private static func defaultTargetPath(for target: SPMTarget) -> String {
        switch target.kind {
        case .test: return "Tests/" + target.name
        default: return "Sources/" + target.name
        }
    }

    // MARK: - Hash Management

    private func updateHashes(projectId: Int64, files: [String]) async throws {
        try await db.dbWriter.write { [fileHasher] db in
            for file in files {
                guard let hash = try? fileHasher.hash(filePath: file) else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO file_hashes (projectId, filePath, sha256, lastIndexed)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT (projectId, filePath) DO UPDATE SET
                            sha256 = excluded.sha256,
                            lastIndexed = excluded.lastIndexed
                        """,
                    arguments: [projectId, file, hash, Date()]
                )
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupDeletedFiles(projectId: Int64, paths: [String]) async throws {
        try await db.dbWriter.write { db in
            for path in paths {
                // Delete symbols from this file (cascades to edges)
                try db.execute(
                    sql: "DELETE FROM symbols WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, path]
                )
                // Delete file hash
                try db.execute(
                    sql: "DELETE FROM file_hashes WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, path]
                )
            }
        }
    }

    // MARK: - Resolve Placeholders

    /// Replace unresolved placeholder symbols with real symbols where they now exist.
    private func resolveUnresolvedPlaceholders(projectId: Int64) async throws {
        try await db.dbWriter.write { db in
            // Find all unresolved placeholders that now have a real symbol
            let placeholders = try Row.fetchAll(db, sql: """
                SELECT p.id AS placeholderId, r.id AS realId
                FROM symbols p
                JOIN symbols r ON r.projectId = p.projectId AND r.name = p.name
                    AND r.qualifiedName NOT LIKE 'unresolved:%'
                    AND r.kind IN ('struct', 'class', 'enum', 'actor')
                WHERE p.projectId = ? AND p.qualifiedName LIKE 'unresolved:%'
                """, arguments: [projectId])

            for row in placeholders {
                let placeholderId: Int64 = row["placeholderId"]
                let realId: Int64 = row["realId"]

                // Repoint edges from placeholder to real symbol
                try db.execute(
                    sql: "UPDATE OR IGNORE edges SET targetId = ? WHERE targetId = ?",
                    arguments: [realId, placeholderId]
                )
                try db.execute(
                    sql: "UPDATE OR IGNORE edges SET sourceId = ? WHERE sourceId = ?",
                    arguments: [realId, placeholderId]
                )

                // Delete the placeholder (cascades remaining duplicate edges)
                try db.execute(
                    sql: "DELETE FROM symbols WHERE id = ?",
                    arguments: [placeholderId]
                )
            }
        }
    }

    // MARK: - Resolve Environment Edges

    /// Create usesEnvironment edges: view → type for @Environment usage.
    /// Cross-references wrapper_usage (wrapperName='Environment') with environment_keys
    /// to find the value type, then links the consuming view to that type.
    private func resolveEnvironmentEdges(projectId: Int64) async throws {
        try await db.dbWriter.write { db in
            // Strategy 1: Match @Environment(\.keyPath) via environment_keys table
            // wrapper_usage.argument like "\.appServices" → strip "\." → "appServices"
            // environment_keys.keyName = "appServices" → valueType = "AppServices"
            // Then find the view (parent of the property via CONTAINS edge) and the type symbol.
            let keyPathUsages = try Row.fetchAll(db, sql: """
                SELECT
                    wu.id AS wrapperUsageId,
                    wu.symbolId AS propertyId,
                    wu.argument,
                    ek.valueType,
                    parentEdge.sourceId AS viewId
                FROM wrapper_usage wu
                JOIN edges parentEdge ON parentEdge.targetId = wu.symbolId
                    AND parentEdge.kind = ?
                JOIN environment_keys ek ON ek.projectId = wu.projectId
                    AND ek.keyName = REPLACE(wu.argument, '\\.', '')
                WHERE wu.projectId = ?
                    AND wu.wrapperName = 'Environment'
                    AND wu.argument LIKE '\\.%'
                    AND ek.valueType IS NOT NULL
                """, arguments: [EdgeKind.contains.rawValue, projectId])

            for row in keyPathUsages {
                let viewId: Int64 = row["viewId"]
                let valueType: String = row["valueType"]

                // Find the type symbol for the value type
                guard let typeId = try Int64.fetchOne(db, sql: """
                    SELECT id FROM symbols
                    WHERE projectId = ? AND name = ?
                        AND kind IN ('struct', 'class', 'enum', 'actor', 'protocol')
                        AND qualifiedName NOT LIKE 'unresolved:%'
                    LIMIT 1
                    """, arguments: [projectId, valueType])
                else { continue }

                // Don't create self-referencing edges
                guard viewId != typeId else { continue }

                var edge = EdgeRecord(
                    projectId: projectId,
                    sourceId: viewId,
                    targetId: typeId,
                    kind: EdgeKind.usesEnvironment.rawValue
                )
                try? edge.insert(db) // Ignore duplicates
            }

            // Strategy 2: Match @Environment(SomeType.self) — iOS 17+ Observable syntax
            let typeSelfUsages = try Row.fetchAll(db, sql: """
                SELECT
                    wu.symbolId AS propertyId,
                    wu.argument,
                    parentEdge.sourceId AS viewId
                FROM wrapper_usage wu
                JOIN edges parentEdge ON parentEdge.targetId = wu.symbolId
                    AND parentEdge.kind = ?
                WHERE wu.projectId = ?
                    AND wu.wrapperName = 'Environment'
                    AND wu.argument LIKE '%.self'
                    AND wu.argument NOT LIKE '\\.%'
                """, arguments: [EdgeKind.contains.rawValue, projectId])

            for row in typeSelfUsages {
                let viewId: Int64 = row["viewId"]
                let argument: String = row["argument"]
                let typeName = String(argument.dropLast(5)) // Remove ".self"

                guard let typeId = try Int64.fetchOne(db, sql: """
                    SELECT id FROM symbols
                    WHERE projectId = ? AND name = ?
                        AND kind IN ('struct', 'class', 'enum', 'actor', 'protocol')
                        AND qualifiedName NOT LIKE 'unresolved:%'
                    LIMIT 1
                    """, arguments: [projectId, typeName])
                else { continue }

                guard viewId != typeId else { continue }

                var edge = EdgeRecord(
                    projectId: projectId,
                    sourceId: viewId,
                    targetId: typeId,
                    kind: EdgeKind.usesEnvironment.rawValue
                )
                try? edge.insert(db)
            }
        }
    }

    // MARK: - Resolve Type References

    /// Create references edges from type_references table.
    /// For extension sources, redirects the edge to the base type via the extends edge.
    private func resolveTypeReferences(projectId: Int64) async throws {
        try await db.dbWriter.write { db in
            // Delete all existing references edges for this project
            try db.execute(
                sql: "DELETE FROM edges WHERE projectId = ? AND kind = ?",
                arguments: [projectId, EdgeKind.references.rawValue]
            )

            // Resolve type references into edges in bulk.
            // For extension sources, follow the extends edge to use the base type as source,
            // so MovieService (not its extension) gets the references edge.
            try db.execute(sql: """
                INSERT OR IGNORE INTO edges (projectId, sourceId, targetId, kind)
                SELECT DISTINCT tr.projectId,
                    COALESCE(baseEdge.targetId, tr.sourceSymbolId),
                    target.id,
                    'references'
                FROM type_references tr
                JOIN symbols sourceSym ON sourceSym.id = tr.sourceSymbolId
                JOIN symbols target ON target.projectId = tr.projectId
                    AND target.name = tr.referencedTypeName
                    AND target.kind IN ('struct', 'class', 'enum', 'actor', 'protocol', 'typeAlias')
                    AND target.qualifiedName NOT LIKE 'unresolved:%'
                LEFT JOIN edges baseEdge ON baseEdge.sourceId = tr.sourceSymbolId
                    AND baseEdge.kind = 'extends'
                    AND sourceSym.kind = 'extension'
                WHERE tr.projectId = ?
                    AND COALESCE(baseEdge.targetId, tr.sourceSymbolId) != target.id
                """, arguments: [projectId])
        }
    }

    // MARK: - Resolve Function Calls

    /// Create calls edges from function_calls table.
    /// Matches callee name + receiver type to symbols in the graph.
    /// For extensions, redirects the source to the base type.
    private func resolveFunctionCalls(projectId: Int64) async throws {
        try await db.dbWriter.write { db in
            // Delete all existing calls edges for this project
            try db.execute(
                sql: "DELETE FROM edges WHERE projectId = ? AND kind = ?",
                arguments: [projectId, EdgeKind.calls.rawValue]
            )

            // Strategy 1: Resolve calls with known receiver type
            // Match receiverType.calleeName to ParentType.methodName in symbols
            try db.execute(sql: """
                INSERT OR IGNORE INTO edges (projectId, sourceId, targetId, kind, metadata)
                SELECT DISTINCT fc.projectId,
                    fc.callerSymbolId,
                    target.id,
                    'calls',
                    fc.callKind
                FROM function_calls fc
                JOIN symbols parent ON parent.projectId = fc.projectId
                    AND parent.name = fc.receiverType
                    AND parent.kind IN ('struct', 'class', 'enum', 'actor', 'protocol')
                    AND parent.qualifiedName NOT LIKE 'unresolved:%'
                JOIN edges ce ON ce.sourceId = parent.id AND ce.kind = 'contains'
                JOIN symbols target ON ce.targetId = target.id
                    AND target.name = fc.calleeName
                    AND target.kind IN ('function', 'variable', 'initializer')
                WHERE fc.projectId = ?
                    AND fc.receiverType IS NOT NULL
                    AND fc.callerSymbolId != target.id
                """, arguments: [projectId])

            // Strategy 2: Resolve init calls — TypeName() → TypeName.init
            try db.execute(sql: """
                INSERT OR IGNORE INTO edges (projectId, sourceId, targetId, kind, metadata)
                SELECT DISTINCT fc.projectId,
                    fc.callerSymbolId,
                    target.id,
                    'calls',
                    'initCall'
                FROM function_calls fc
                JOIN symbols parent ON parent.projectId = fc.projectId
                    AND parent.name = fc.receiverType
                    AND parent.kind IN ('struct', 'class', 'enum', 'actor')
                    AND parent.qualifiedName NOT LIKE 'unresolved:%'
                JOIN edges ce ON ce.sourceId = parent.id AND ce.kind = 'contains'
                JOIN symbols target ON ce.targetId = target.id
                    AND target.kind = 'initializer'
                WHERE fc.projectId = ?
                    AND fc.callKind = 'initCall'
                    AND fc.callerSymbolId != target.id
                """, arguments: [projectId])

            // Strategy 3: Free function calls (no receiver type, callKind = freeCall)
            // Match by name against top-level functions
            try db.execute(sql: """
                INSERT OR IGNORE INTO edges (projectId, sourceId, targetId, kind, metadata)
                SELECT DISTINCT fc.projectId,
                    fc.callerSymbolId,
                    target.id,
                    'calls',
                    'freeCall'
                FROM function_calls fc
                JOIN symbols target ON target.projectId = fc.projectId
                    AND target.name = fc.calleeName
                    AND target.kind = 'function'
                    AND target.qualifiedName NOT LIKE 'unresolved:%'
                    -- Only match top-level functions (not members)
                    AND NOT EXISTS (
                        SELECT 1 FROM edges me WHERE me.targetId = target.id AND me.kind = 'contains'
                    )
                WHERE fc.projectId = ?
                    AND fc.callKind = 'freeCall'
                    AND fc.callerSymbolId != target.id
                """, arguments: [projectId])
        }
    }

    // MARK: - Helpers

    static func buildQualifiedName(decl: ExtractedDeclaration, filePath: String) -> String {
        let fileName = URL(filePath: filePath).lastPathComponent

        if decl.kind == .extension {
            return "\(decl.name)+\(fileName):\(decl.line)"
        }

        if let parent = decl.parent {
            return "\(parent).\(decl.name)"
        }

        // Top-level functions/variables need file context to avoid collisions
        switch decl.kind {
        case .function, .variable, .initializer:
            return "\(fileName):\(decl.name)"
        default:
            return decl.name
        }
    }

    static func encodeJSON(_ array: [String]) -> String? {
        guard !array.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(array),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

// MARK: - Result

public struct IndexResult: Sendable {
    public let projectId: Int64
    public let totalFiles: Int
    public let indexedFiles: Int
    public let deletedFiles: Int
    public let modules: Int
    public let totalSymbols: Int
    public let totalEdges: Int
}

// MARK: - Project Config

public struct ProjectConfig: Sendable {
    public let exclude: Set<String>
    public let packages: [String]

    public static let `default` = ProjectConfig(exclude: [], packages: [])

    public init(exclude: Set<String>, packages: [String]) {
        self.exclude = exclude
        self.packages = packages
    }
}
