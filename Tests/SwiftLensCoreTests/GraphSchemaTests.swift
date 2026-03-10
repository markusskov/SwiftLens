import Testing
import GRDB
@testable import SwiftLensCore

@Suite("GraphSchema")
struct GraphSchemaTests {

    @Test("Database creates with all tables")
    func createDatabase() throws {
        let db = try GraphDatabase.inMemory()

        // Verify all tables exist
        let tables = try db.dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table'
                ORDER BY name
                """)
        }

        #expect(tables.contains("projects"))
        #expect(tables.contains("modules"))
        #expect(tables.contains("module_deps"))
        #expect(tables.contains("symbols"))
        #expect(tables.contains("edges"))
        #expect(tables.contains("file_hashes"))
        #expect(tables.contains("environment_keys"))
        #expect(tables.contains("wrapper_usage"))
        #expect(tables.contains("symbols_fts"))
    }

    @Test("Can insert and query symbols")
    func insertAndQuerySymbols() throws {
        let db = try GraphDatabase.inMemory()

        try db.dbWriter.write { db in
            var project = ProjectRecord(name: "Test", rootPath: "/test")
            try project.insert(db)

            var symbol = SymbolRecord(
                projectId: project.id!,
                kind: NodeKind.struct.rawValue,
                name: "MyView",
                qualifiedName: "MyView",
                filePath: "/test/MyView.swift",
                line: 1,
                column: 1,
                accessLevel: "public",
                inheritedTypes: "[\"View\"]"
            )
            try symbol.insert(db)

            let fetched = try SymbolRecord.fetchOne(db, key: symbol.id!)
            #expect(fetched?.name == "MyView")
            #expect(fetched?.kind == "struct")
            #expect(fetched?.accessLevel == "public")
        }
    }

    @Test("FTS5 search works")
    func fts5Search() throws {
        let db = try GraphDatabase.inMemory()

        try db.dbWriter.write { db in
            var project = ProjectRecord(name: "Test", rootPath: "/test")
            try project.insert(db)

            var symbol = SymbolRecord(
                projectId: project.id!,
                kind: NodeKind.struct.rawValue,
                name: "HomeViewModel",
                qualifiedName: "HomeViewModel"
            )
            try symbol.insert(db)
        }

        let results = try db.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.* FROM symbols s
                JOIN symbols_fts ON symbols_fts.rowid = s.rowid
                WHERE symbols_fts MATCH 'Home*'
                """)
        }

        #expect(results.count == 1)
        #expect(results.first?["name"] as String? == "HomeViewModel")
    }

    @Test("Edges cascade on symbol delete")
    func edgeCascade() throws {
        let db = try GraphDatabase.inMemory()

        try db.dbWriter.write { db in
            var project = ProjectRecord(name: "Test", rootPath: "/test")
            try project.insert(db)

            var s1 = SymbolRecord(
                projectId: project.id!, kind: "struct", name: "A", qualifiedName: "A"
            )
            try s1.insert(db)

            var s2 = SymbolRecord(
                projectId: project.id!, kind: "protocol", name: "P", qualifiedName: "P"
            )
            try s2.insert(db)

            var edge = EdgeRecord(
                projectId: project.id!, sourceId: s1.id!, targetId: s2.id!,
                kind: EdgeKind.conformsTo.rawValue
            )
            try edge.insert(db)

            // Verify edge exists
            let edgeCount = try EdgeRecord.fetchCount(db)
            #expect(edgeCount == 1)

            // Delete source symbol — edge should cascade
            try s1.delete(db)
            let edgeCountAfter = try EdgeRecord.fetchCount(db)
            #expect(edgeCountAfter == 0)
        }
    }
}
