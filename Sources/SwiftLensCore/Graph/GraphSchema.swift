import GRDB
import Foundation

/// Manages database migrations for the SwiftLens knowledge graph.
public struct GraphSchema: Sendable {

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_core_tables") { db in
            // Projects
            try db.create(table: "projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("rootPath", .text).notNull().unique()
                t.column("lastIndexed", .datetime)
            }

            // Modules (SPM targets)
            try db.create(table: "modules") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", inTable: "projects").notNull()
                t.column("name", .text).notNull()
                t.column("path", .text)
                t.column("kind", .text).notNull()
                t.uniqueKey(["projectId", "name"])
            }

            // Module dependencies
            try db.create(table: "module_deps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("module", inTable: "modules").notNull()
                t.column("dependencyId", .integer)
                    .notNull()
                    .references("modules", onDelete: .cascade)
                t.uniqueKey(["moduleId", "dependencyId"])
            }

            // Symbols (all declaration types)
            try db.create(table: "symbols") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", inTable: "projects").notNull()
                t.column("moduleId", .integer).references("modules", onDelete: .setNull)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("qualifiedName", .text).notNull()
                t.column("filePath", .text)
                t.column("line", .integer)
                t.column("column", .integer)
                t.column("endLine", .integer)
                t.column("accessLevel", .text)
                t.column("attributes", .text)    // JSON array
                t.column("modifiers", .text)     // JSON array
                t.column("inheritedTypes", .text) // JSON array
                t.column("signature", .text)
                t.column("documentation", .text)
                t.column("usr", .text)
                t.uniqueKey(["projectId", "qualifiedName"])
            }

            // Edges (relationships)
            try db.create(table: "edges") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", inTable: "projects").notNull()
                t.column("sourceId", .integer)
                    .notNull()
                    .references("symbols", onDelete: .cascade)
                t.column("targetId", .integer)
                    .notNull()
                    .references("symbols", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("metadata", .text)
                t.uniqueKey(["sourceId", "targetId", "kind"])
            }

            // File hashes for incremental indexing
            try db.create(table: "file_hashes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", inTable: "projects").notNull()
                t.column("filePath", .text).notNull()
                t.column("sha256", .text).notNull()
                t.column("lastIndexed", .datetime).notNull()
                t.uniqueKey(["projectId", "filePath"])
            }

            // Environment key declarations
            try db.create(table: "environment_keys") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", inTable: "projects").notNull()
                t.column("keyName", .text).notNull()
                t.column("valueType", .text)
                t.column("declaringSymbolId", .integer)
                    .references("symbols", onDelete: .setNull)
                t.column("filePath", .text)
                t.column("line", .integer)
                t.uniqueKey(["projectId", "keyName"])
            }

            // Property wrapper usage
            try db.create(table: "wrapper_usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", inTable: "projects").notNull()
                t.column("symbolId", .integer)
                    .notNull()
                    .references("symbols", onDelete: .cascade)
                t.column("wrapperName", .text).notNull()
                t.column("argument", .text)
                t.column("filePath", .text)
                t.column("line", .integer)
            }

            // Indexes for common queries
            try db.create(indexOn: "symbols", columns: ["projectId", "kind"])
            try db.create(indexOn: "symbols", columns: ["projectId", "name"])
            try db.create(indexOn: "symbols", columns: ["moduleId"])
            try db.create(indexOn: "symbols", columns: ["filePath"])
            try db.create(indexOn: "edges", columns: ["sourceId", "kind"])
            try db.create(indexOn: "edges", columns: ["targetId", "kind"])
            try db.create(indexOn: "edges", columns: ["projectId", "kind"])
            try db.create(indexOn: "file_hashes", columns: ["projectId", "sha256"])
            try db.create(indexOn: "wrapper_usage", columns: ["symbolId"])
        }

        migrator.registerMigration("v1_fts5") { db in
            try db.create(virtualTable: "symbols_fts", using: FTS5()) { t in
                t.synchronize(withTable: "symbols")
                t.tokenizer = .unicode61()
                t.column("name")
                t.column("qualifiedName")
            }
        }

        return migrator
    }
}
