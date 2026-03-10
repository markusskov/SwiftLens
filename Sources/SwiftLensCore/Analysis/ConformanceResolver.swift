import GRDB
import Foundation

/// Resolves protocol conformances and inheritance across all symbols in the project.
public struct ConformanceResolver: Sendable {
    private let db: GraphDatabase

    public init(db: GraphDatabase) {
        self.db = db
    }

    /// Build CONFORMS_TO and INHERITS edges from inheritedTypes JSON arrays.
    public func resolve(projectId: Int64) async throws {
        try await db.dbWriter.write { db in
            // Remove existing conformance/inheritance edges (except extension-derived ones)
            try db.execute(
                sql: """
                    DELETE FROM edges
                    WHERE projectId = ? AND kind IN (?, ?)
                    AND (metadata IS NULL OR metadata NOT LIKE '%via_extension%')
                    """,
                arguments: [projectId, EdgeKind.conformsTo.rawValue, EdgeKind.inherits.rawValue]
            )

            // Get all type symbols with inherited types
            let types = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("kind") != NodeKind.extension.rawValue)
                .filter(Column("kind") != NodeKind.file.rawValue)
                .filter(Column("kind") != NodeKind.module.rawValue)
                .filter(Column("kind") != NodeKind.function.rawValue)
                .filter(Column("kind") != NodeKind.variable.rawValue)
                .filter(Column("inheritedTypes") != nil)
                .fetchAll(db)

            // Build a name → symbol lookup
            let allTypeSymbols = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter([
                    NodeKind.protocol.rawValue,
                    NodeKind.class.rawValue,
                    NodeKind.struct.rawValue,
                    NodeKind.enum.rawValue,
                    NodeKind.actor.rawValue,
                ].contains(Column("kind")))
                .fetchAll(db)

            let nameToSymbol = Dictionary(
                allTypeSymbols.compactMap { s in s.id.map { (s.name, $0) } },
                uniquingKeysWith: { first, _ in first }
            )

            for type in types {
                guard let typeId = type.id,
                      let json = type.inheritedTypes,
                      let inherited = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
                else { continue }

                for parentName in inherited {
                    guard let targetId = nameToSymbol[parentName] else { continue }

                    // Determine if this is inheritance (class→class) or conformance
                    let targetKind = allTypeSymbols
                        .first { $0.id == targetId }
                        .map(\.kind)

                    let edgeKind: EdgeKind
                    if type.kind == NodeKind.class.rawValue && targetKind == NodeKind.class.rawValue {
                        edgeKind = .inherits
                    } else {
                        edgeKind = .conformsTo
                    }

                    var edge = EdgeRecord(
                        projectId: projectId,
                        sourceId: typeId,
                        targetId: targetId,
                        kind: edgeKind.rawValue
                    )
                    try? edge.insert(db) // Ignore duplicates
                }
            }
        }
    }
}
