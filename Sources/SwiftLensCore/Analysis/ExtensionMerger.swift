import GRDB
import Foundation

/// Links extension symbols to their base type symbols via EXTENDS edges.
public struct ExtensionMerger: Sendable {
    private let db: GraphDatabase

    public init(db: GraphDatabase) {
        self.db = db
    }

    /// Find all extension symbols and create EXTENDS edges to their base types.
    public func merge(projectId: Int64) async throws {
        try await db.dbWriter.write { db in
            // Remove existing EXTENDS edges for this project (rebuild)
            try db.execute(
                sql: "DELETE FROM edges WHERE projectId = ? AND kind = ?",
                arguments: [projectId, EdgeKind.extends.rawValue]
            )

            // Find all extension symbols
            let extensions = try SymbolRecord
                .filter(Column("projectId") == projectId)
                .filter(Column("kind") == NodeKind.extension.rawValue)
                .fetchAll(db)

            for ext in extensions {
                // Extension name is the base type name (e.g. "EnvironmentValues")
                // Qualified name is "TypeName+FileName:Line"
                let baseTypeName = ext.name

                // Find the base type symbol (struct, class, enum, protocol, actor)
                let baseType = try SymbolRecord
                    .filter(Column("projectId") == projectId)
                    .filter(Column("name") == baseTypeName)
                    .filter(Column("kind") != NodeKind.extension.rawValue)
                    .filter(Column("kind") != NodeKind.file.rawValue)
                    .filter(Column("kind") != NodeKind.module.rawValue)
                    .filter(Column("kind") != NodeKind.function.rawValue)
                    .filter(Column("kind") != NodeKind.variable.rawValue)
                    .fetchOne(db)

                guard let baseType, let baseId = baseType.id, let extId = ext.id else {
                    continue
                }

                var edge = EdgeRecord(
                    projectId: projectId,
                    sourceId: extId,
                    targetId: baseId,
                    kind: EdgeKind.extends.rawValue
                )
                try? edge.insert(db) // Ignore duplicates

                // Also propagate conformances from extension's inheritedTypes
                if let inheritedJSON = ext.inheritedTypes,
                   let types = try? JSONDecoder().decode([String].self, from: Data(inheritedJSON.utf8)) {
                    for typeName in types {
                        // Find the protocol/type
                        let target = try SymbolRecord
                            .filter(Column("projectId") == projectId)
                            .filter(Column("name") == typeName)
                            .filter(Column("kind") == NodeKind.protocol.rawValue)
                            .fetchOne(db)

                        if let target, let targetId = target.id {
                            // Create CONFORMS_TO from the base type to the protocol
                            var conformEdge = EdgeRecord(
                                projectId: projectId,
                                sourceId: baseId,
                                targetId: targetId,
                                kind: EdgeKind.conformsTo.rawValue,
                                metadata: "{\"via_extension\":true}"
                            )
                            try? conformEdge.insert(db)
                        }
                    }
                }
            }
        }
    }
}
