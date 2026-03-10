import Testing
import GRDB
@testable import SwiftLensCore

@Suite("QueryEngine")
struct QueryEngineTests {

    private func setupDB() throws -> (GraphDatabase, Int64) {
        let db = try GraphDatabase.inMemory()
        let projectId = try db.dbWriter.write { db -> Int64 in
            var project = ProjectRecord(name: "Test", rootPath: "/test")
            try project.insert(db)
            return project.id!
        }
        return (db, projectId)
    }

    @Test("search_symbol returns FTS5 results")
    func searchSymbol() throws {
        let (db, projectId) = try setupDB()

        try db.dbWriter.write { db in
            var s1 = SymbolRecord(
                projectId: projectId, kind: "struct", name: "HomeViewModel",
                qualifiedName: "HomeViewModel", filePath: "/test/Home.swift", line: 10
            )
            try s1.insert(db)

            var s2 = SymbolRecord(
                projectId: projectId, kind: "struct", name: "HomeTab",
                qualifiedName: "HomeTab", filePath: "/test/HomeTab.swift", line: 5
            )
            try s2.insert(db)

            var s3 = SymbolRecord(
                projectId: projectId, kind: "struct", name: "SettingsView",
                qualifiedName: "SettingsView"
            )
            try s3.insert(db)
        }

        let engine = QueryEngine(db: db)
        let results = try engine.searchSymbol(projectId: projectId, query: "Home")

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.name.contains("Home") })
    }

    @Test("find_conformers returns conforming types")
    func findConformers() throws {
        let (db, projectId) = try setupDB()

        try db.dbWriter.write { db in
            var proto = SymbolRecord(
                projectId: projectId, kind: "protocol", name: "VODQuerying",
                qualifiedName: "VODQuerying"
            )
            try proto.insert(db)

            var conformer1 = SymbolRecord(
                projectId: projectId, kind: "struct", name: "VODRepository",
                qualifiedName: "VODRepository", filePath: "/test/VODRepo.swift", line: 1
            )
            try conformer1.insert(db)

            var conformer2 = SymbolRecord(
                projectId: projectId, kind: "class", name: "MockVODQuerying",
                qualifiedName: "MockVODQuerying", filePath: "/test/Mocks.swift", line: 1
            )
            try conformer2.insert(db)

            var edge1 = EdgeRecord(
                projectId: projectId, sourceId: conformer1.id!, targetId: proto.id!,
                kind: EdgeKind.conformsTo.rawValue
            )
            try edge1.insert(db)

            var edge2 = EdgeRecord(
                projectId: projectId, sourceId: conformer2.id!, targetId: proto.id!,
                kind: EdgeKind.conformsTo.rawValue
            )
            try edge2.insert(db)
        }

        let engine = QueryEngine(db: db)
        let results = try engine.findConformers(projectId: projectId, protocolName: "VODQuerying")

        #expect(results.count == 2)
        #expect(results.map(\.name).contains("VODRepository"))
        #expect(results.map(\.name).contains("MockVODQuerying"))
    }

    @Test("get_symbol returns members and conformances")
    func getSymbol() throws {
        let (db, projectId) = try setupDB()

        try db.dbWriter.write { db in
            var proto = SymbolRecord(
                projectId: projectId, kind: "protocol", name: "Sendable",
                qualifiedName: "Sendable"
            )
            try proto.insert(db)

            var structSym = SymbolRecord(
                projectId: projectId, kind: "struct", name: "Config",
                qualifiedName: "Config", filePath: "/test/Config.swift", line: 1
            )
            try structSym.insert(db)

            var member = SymbolRecord(
                projectId: projectId, kind: "variable", name: "path",
                qualifiedName: "Config.path", filePath: "/test/Config.swift", line: 2
            )
            try member.insert(db)

            // CONTAINS edge
            var containsEdge = EdgeRecord(
                projectId: projectId, sourceId: structSym.id!, targetId: member.id!,
                kind: EdgeKind.contains.rawValue
            )
            try containsEdge.insert(db)

            // CONFORMS_TO edge
            var conformsEdge = EdgeRecord(
                projectId: projectId, sourceId: structSym.id!, targetId: proto.id!,
                kind: EdgeKind.conformsTo.rawValue
            )
            try conformsEdge.insert(db)
        }

        let engine = QueryEngine(db: db)
        let detail = try engine.getSymbol(projectId: projectId, qualifiedName: "Config")

        #expect(detail != nil)
        #expect(detail?.symbol.name == "Config")
        #expect(detail?.members.count == 1)
        #expect(detail?.members.first?.name == "path")
        #expect(detail?.conformances.count == 1)
        #expect(detail?.conformances.first?.name == "Sendable")
    }

    @Test("trace_view_tree traverses composition edges")
    func traceViewTree() throws {
        let (db, projectId) = try setupDB()

        try db.dbWriter.write { db in
            var parent = SymbolRecord(
                projectId: projectId, kind: "struct", name: "ContentView",
                qualifiedName: "ContentView", filePath: "/test/Content.swift", line: 1
            )
            try parent.insert(db)

            var child1 = SymbolRecord(
                projectId: projectId, kind: "struct", name: "HomeTab",
                qualifiedName: "HomeTab", filePath: "/test/Home.swift", line: 1
            )
            try child1.insert(db)

            var child2 = SymbolRecord(
                projectId: projectId, kind: "struct", name: "SearchTab",
                qualifiedName: "SearchTab", filePath: "/test/Search.swift", line: 1
            )
            try child2.insert(db)

            var edge1 = EdgeRecord(
                projectId: projectId, sourceId: parent.id!, targetId: child1.id!,
                kind: EdgeKind.composesView.rawValue
            )
            try edge1.insert(db)

            var edge2 = EdgeRecord(
                projectId: projectId, sourceId: parent.id!, targetId: child2.id!,
                kind: EdgeKind.composesView.rawValue
            )
            try edge2.insert(db)
        }

        let engine = QueryEngine(db: db)
        let tree = try engine.traceViewTree(projectId: projectId, rootView: "ContentView")

        #expect(tree.name == "ContentView")
        #expect(tree.children.count == 2)
        #expect(tree.children.map(\.name).contains("HomeTab"))
        #expect(tree.children.map(\.name).contains("SearchTab"))
    }
}
