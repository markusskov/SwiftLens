import Foundation
import GRDB
import IndexStore

/// Enriches the SwiftLens knowledge graph using data from the Swift compiler's index store.
/// The index store contains compiler-resolved type information, USRs, and call relationships
/// that are impossible to determine from AST analysis alone.
public struct IndexStoreEnricher: Sendable {
    private let db: GraphDatabase

    public init(db: GraphDatabase) {
        self.db = db
    }

    /// Result of an enrichment pass.
    public struct EnrichmentResult: Sendable {
        public let usrsPopulated: Int
        public let callEdgesCreated: Int
        public let overrideEdgesCreated: Int
        public let requirementEdgesCreated: Int
        public let receiverTypesBackfilled: Int

        public static let empty = EnrichmentResult(
            usrsPopulated: 0, callEdgesCreated: 0,
            overrideEdgesCreated: 0, requirementEdgesCreated: 0,
            receiverTypesBackfilled: 0
        )
    }

    // MARK: - Extracted Data Types

    private struct DefinitionData {
        let filePath: String
        let line: Int
        let name: String
        let usr: String
    }

    private struct CallData {
        let calleeUSR: String
        let calleeName: String
        let callerUSR: String
        let filePath: String
        let line: Int
    }

    private struct RelationData {
        let childUSR: String
        let parentUSR: String
    }

    private struct RecordDepInfo {
        let recordName: String
        let filePath: String
    }

    // MARK: - Main Entry Point

    /// Enrich the knowledge graph with data from the index store.
    public func enrich(
        projectId: Int64,
        indexStorePath: String,
        projectRoot: String
    ) async throws -> EnrichmentResult {
        guard let libPath = IndexStorePathResolver.findLibIndexStorePath() else {
            return .empty
        }

        let library = try await IndexStoreLibrary.at(
            dylibPath: URL(fileURLWithPath: libPath)
        )
        let store = try library.indexStore(
            at: URL(fileURLWithPath: indexStorePath)
        )

        let normalizedRoot = normalizePath(projectRoot)

        // Phase 1: Extract all relevant data from index store
        let (definitions, callOccurrences, overrideRelations, requirementRelations) =
            extractFromStore(store: store, normalizedRoot: normalizedRoot)

        // Phase 2: Populate USRs in database
        let usrsPopulated = try await populateUSRs(
            projectId: projectId, definitions: definitions
        )

        // Phase 3: Build USR → symbolId map
        let usrMap = try await buildUSRMap(projectId: projectId)

        // Phase 4: Create call edges from index store data
        let callEdges = try await createCallEdges(
            projectId: projectId, calls: callOccurrences, usrMap: usrMap
        )

        // Phase 5: Create override edges
        let overrideEdges = try await createRelationEdges(
            projectId: projectId, relations: overrideRelations,
            edgeKind: .overrides, usrMap: usrMap
        )

        // Phase 6: Create requirement edges
        let requirementEdges = try await createRelationEdges(
            projectId: projectId, relations: requirementRelations,
            edgeKind: .implementsRequirement, usrMap: usrMap
        )

        // Phase 7: Backfill receiver types and resolve newly-typed calls
        let backfilled = try await backfillReceiverTypes(
            projectId: projectId, calls: callOccurrences, usrMap: usrMap
        )

        return EnrichmentResult(
            usrsPopulated: usrsPopulated,
            callEdgesCreated: callEdges,
            overrideEdgesCreated: overrideEdges,
            requirementEdgesCreated: requirementEdges,
            receiverTypesBackfilled: backfilled
        )
    }

    // MARK: - Phase 1: Index Store Extraction

    private func extractFromStore(
        store: IndexStore,
        normalizedRoot: String
    ) -> (
        definitions: [DefinitionData],
        calls: [CallData],
        overrides: [RelationData],
        requirements: [RelationData]
    ) {
        var definitions: [DefinitionData] = []
        var callOccurrences: [CallData] = []
        var overrideRelations: [RelationData] = []
        var requirementRelations: [RelationData] = []
        var processedRecords: Set<String> = []

        // Step 1: Collect unit → record dependency mappings
        let unitRecordDeps: [(mainFile: String, deps: [RecordDepInfo])] =
            store.unitNames(sorted: false).compactMap { unitNameRef in
                guard let unit = try? store.unit(named: unitNameRef) else { return nil }
                guard !unit.isSystemUnit else { return nil }
                let mainFile = unit.mainFile.string
                guard mainFile.hasPrefix(normalizedRoot) else { return nil }

                let deps: [RecordDepInfo] = unit.dependencies.compactMap { dep in
                    let name = dep.name.string
                    guard !name.isEmpty else { return nil }
                    let filePath = dep.filePath.string
                    return RecordDepInfo(recordName: name, filePath: filePath)
                }
                return (mainFile, deps)
            }

        // Step 2: Load records and extract occurrences
        for (_, deps) in unitRecordDeps {
            for dep in deps {
                guard processedRecords.insert(dep.recordName).inserted else { continue }

                let filePath = normalizePath(dep.filePath)
                guard filePath.hasPrefix(normalizedRoot),
                      filePath.hasSuffix(".swift") else { continue }

                guard let record = try? store.record(named: dep.recordName) else { continue }

                // Extract all occurrences from this record
                record.occurrences.forEach { occ in
                    let symbolUSR = occ.symbol.usr.string
                    let symbolName = occ.symbol.name.string
                    let line = occ.position.line
                    let roles = occ.roles

                    // Collect definitions for USR population
                    if roles.contains(.definition) && !symbolUSR.isEmpty {
                        let simpleName = extractSimpleName(symbolName)
                        definitions.append(DefinitionData(
                            filePath: filePath,
                            line: line,
                            name: simpleName,
                            usr: symbolUSR
                        ))
                    }

                    // Collect call/override/requirement relations
                    if roles.contains(.call) || roles.contains(.definition) || roles.contains(.reference) {
                        occ.relations.forEach { rel in
                            let relUSR = rel.symbol.usr.string
                            let relRoles = rel.roles

                            if roles.contains(.call) && relRoles.contains(.calledBy) {
                                callOccurrences.append(CallData(
                                    calleeUSR: symbolUSR,
                                    calleeName: symbolName,
                                    callerUSR: relUSR,
                                    filePath: filePath,
                                    line: line
                                ))
                            }

                            if relRoles.contains(.overrideOf) {
                                overrideRelations.append(RelationData(
                                    childUSR: symbolUSR,
                                    parentUSR: relUSR
                                ))
                            }

                            if relRoles.contains(.baseOf) {
                                requirementRelations.append(RelationData(
                                    childUSR: relUSR,
                                    parentUSR: symbolUSR
                                ))
                            }

                            return .continue
                        }
                    }

                    return .continue
                }
            }
        }

        return (definitions, callOccurrences, overrideRelations, requirementRelations)
    }

    // MARK: - Phase 2: USR Population

    private func populateUSRs(
        projectId: Int64,
        definitions: [DefinitionData]
    ) async throws -> Int {
        try await db.dbWriter.write { db in
            var count = 0
            for def in definitions {
                try db.execute(
                    sql: """
                        UPDATE symbols SET usr = ?
                        WHERE projectId = ? AND filePath = ? AND line = ? AND name = ?
                        AND usr IS NULL
                        """,
                    arguments: [def.usr, projectId, def.filePath, def.line, def.name]
                )
                count += db.changesCount
            }
            return count
        }
    }

    // MARK: - Phase 3: USR Map

    private func buildUSRMap(projectId: Int64) async throws -> [String: Int64] {
        try await db.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT usr, id FROM symbols
                WHERE projectId = ? AND usr IS NOT NULL
                """, arguments: [projectId])

            var map: [String: Int64] = [:]
            map.reserveCapacity(rows.count)
            for row in rows {
                let usr: String = row["usr"]
                let id: Int64 = row["id"]
                map[usr] = id
            }
            return map
        }
    }

    // MARK: - Phase 4: Call Edge Creation

    private func createCallEdges(
        projectId: Int64,
        calls: [CallData],
        usrMap: [String: Int64]
    ) async throws -> Int {
        try await db.dbWriter.write { db in
            var count = 0
            for call in calls {
                guard let callerId = usrMap[call.callerUSR],
                      let calleeId = usrMap[call.calleeUSR],
                      callerId != calleeId else { continue }

                var edge = EdgeRecord(
                    projectId: projectId,
                    sourceId: callerId,
                    targetId: calleeId,
                    kind: EdgeKind.calls.rawValue,
                    metadata: "indexStore"
                )
                do {
                    try edge.insert(db)
                    count += 1
                } catch {
                    // Ignore duplicate edge errors
                }
            }
            return count
        }
    }

    // MARK: - Phase 5/6: Relation Edge Creation

    private func createRelationEdges(
        projectId: Int64,
        relations: [RelationData],
        edgeKind: EdgeKind,
        usrMap: [String: Int64]
    ) async throws -> Int {
        try await db.dbWriter.write { db in
            var count = 0
            for rel in relations {
                guard let childId = usrMap[rel.childUSR],
                      let parentId = usrMap[rel.parentUSR],
                      childId != parentId else { continue }

                var edge = EdgeRecord(
                    projectId: projectId,
                    sourceId: childId,
                    targetId: parentId,
                    kind: edgeKind.rawValue
                )
                do {
                    try edge.insert(db)
                    count += 1
                } catch {
                    // Ignore duplicate edge errors
                }
            }
            return count
        }
    }

    // MARK: - Phase 7: Receiver Type Backfill

    private func backfillReceiverTypes(
        projectId: Int64,
        calls: [CallData],
        usrMap: [String: Int64]
    ) async throws -> Int {
        // Build lookup: (filePath:line:calleeName) → calleeUSR
        var callLookupBuilder: [String: String] = [:]
        for call in calls {
            let simpleName = extractSimpleName(call.calleeName)
            let key = call.filePath + ":" + String(call.line) + ":" + simpleName
            callLookupBuilder[key] = call.calleeUSR
        }
        let callLookup = callLookupBuilder

        return try await db.dbWriter.write { [callLookup] db in
            // Get all unresolved function calls
            let unresolvedCalls = try Row.fetchAll(db, sql: """
                SELECT fc.id, fc.filePath, fc.line, fc.calleeName
                FROM function_calls fc
                WHERE fc.projectId = ? AND fc.receiverType IS NULL
                """, arguments: [projectId])

            var count = 0

            for row in unresolvedCalls {
                let callId: Int64 = row["id"]
                let filePath: String = row["filePath"]
                let line: Int = row["line"]
                let calleeName: String = row["calleeName"]

                let key = filePath + ":" + String(line) + ":" + calleeName
                guard let calleeUSR = callLookup[key] else { continue }
                guard let calleeId = usrMap[calleeUSR] else { continue }

                // Find the parent type of the callee via contains edge
                guard let parentName = try String.fetchOne(db, sql: """
                    SELECT s.name FROM edges e
                    JOIN symbols s ON s.id = e.sourceId
                    WHERE e.targetId = ? AND e.kind = 'contains'
                    AND s.kind IN ('struct', 'class', 'enum', 'actor', 'protocol')
                    LIMIT 1
                    """, arguments: [calleeId]) else { continue }

                try db.execute(
                    sql: "UPDATE function_calls SET receiverType = ? WHERE id = ?",
                    arguments: [parentName, callId]
                )
                count += 1
            }

            // Resolve newly-backfilled calls to edges using the same logic
            // as resolveFunctionCalls Strategy 1, but INSERT OR IGNORE to avoid
            // duplicating edges already created by the AST pipeline or index store.
            if count > 0 {
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
            }

            return count
        }
    }

    // MARK: - Helpers

    /// Extract simple name from index store symbol name.
    /// Index store names include parameter labels: "fetchMovie(id:)" → "fetchMovie"
    private func extractSimpleName(_ name: String) -> String {
        if let parenIndex = name.firstIndex(of: "(") {
            return String(name[name.startIndex..<parenIndex])
        }
        return name
    }

    /// Normalize a file path by resolving symlinks.
    private func normalizePath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}
