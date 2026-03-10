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
        config: ProjectConfig = .default
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
        try await buildModules(projectId: projectId, targets: allTargets)

        // Build file→module mapping
        let fileModuleMap = buildFileModuleMapping(
            projectRoot: projectRoot,
            targets: allTargets,
            files: allFiles
        )

        // Stage 2: Incremental Filter
        let (changedFiles, deletedFiles) = try await filterChangedFiles(
            projectId: projectId,
            files: allFiles
        )

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
        let merger = ExtensionMerger(db: db)
        try await merger.merge(projectId: projectId)

        let conformanceResolver = ConformanceResolver(db: db)
        try await conformanceResolver.resolve(projectId: projectId)

        return IndexResult(
            projectId: projectId,
            totalFiles: allFiles.count,
            indexedFiles: changedFiles.count,
            deletedFiles: deletedFiles.count,
            modules: allTargets.count
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
            for result in results {
                let moduleId = fileModuleMap[result.filePath]

                // First pass: insert all declarations as symbols
                var symbolIds: [String: Int64] = [:] // qualifiedName → id

                // Remove old symbols from this file
                try db.execute(
                    sql: "DELETE FROM symbols WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )

                // Remove old wrapper usages from this file
                try db.execute(
                    sql: "DELETE FROM wrapper_usage WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )

                // Remove old environment keys from this file
                try db.execute(
                    sql: "DELETE FROM environment_keys WHERE projectId = ? AND filePath = ?",
                    arguments: [projectId, result.filePath]
                )

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

                // Process view compositions
                for comp in result.viewCompositions {
                    // Find parent view symbol
                    let parentQN = result.declarations
                        .filter { $0.name == comp.parentView }
                        .first
                        .map { Self.buildQualifiedName(decl: $0, filePath: result.filePath) }

                    guard let parentQN, let parentId = symbolIds[parentQN] else { continue }

                    // Find or create child view symbol (might be in another file)
                    var childId = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM symbols WHERE projectId = ? AND name = ? AND kind IN ('struct', 'class')",
                        arguments: [projectId, comp.childView]
                    )

                    if childId == nil {
                        // Create a placeholder symbol for the child view
                        var placeholder = SymbolRecord(
                            projectId: projectId,
                            kind: NodeKind.struct.rawValue,
                            name: comp.childView,
                            qualifiedName: "unresolved:\(comp.childView)"
                        )
                        try? placeholder.insert(db)
                        childId = placeholder.id ?? (try? Int64.fetchOne(
                            db,
                            sql: "SELECT id FROM symbols WHERE projectId = ? AND qualifiedName = ?",
                            arguments: [projectId, "unresolved:\(comp.childView)"]
                        ))
                    }

                    if let childId {
                        var edge = EdgeRecord(
                            projectId: projectId,
                            sourceId: parentId,
                            targetId: childId,
                            kind: EdgeKind.composesView.rawValue
                        )
                        try? edge.insert(db) // Ignore duplicate edge errors
                    }
                }
            }
        }
    }

    // MARK: - Module Building

    private func buildModules(projectId: Int64, targets: [SPMTarget]) async throws {
        try await db.dbWriter.write { db in
            // Clear existing modules for this project
            try db.execute(
                sql: "DELETE FROM modules WHERE projectId = ?",
                arguments: [projectId]
            )

            var moduleIds: [String: Int64] = [:]

            // Insert all targets
            for target in targets {
                var module = ModuleRecord(
                    projectId: projectId,
                    name: target.name,
                    path: target.path,
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
        }
    }

    // MARK: - File→Module Mapping

    private func buildFileModuleMapping(
        projectRoot: String,
        targets: [SPMTarget],
        files: [String]
    ) -> [String: Int64] {
        // For now, return empty mapping. This will be populated after modules are in the DB.
        // The mapping is: file path → module ID based on directory containment.
        // This is handled lazily during assembly.
        [:]
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
