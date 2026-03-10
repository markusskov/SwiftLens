import Testing
@testable import SwiftLensCore

@Suite("DeclarationVisitor")
struct DeclarationVisitorTests {

    private func extract(_ source: String) -> FileExtractionResult {
        SwiftFileIndexer().index(source: source, filePath: "/test.swift")
    }

    @Test("Extracts struct declaration")
    func structDecl() {
        let result = extract("""
        public struct MyView: View {
            var body: some View { Text("Hi") }
        }
        """)

        let structs = result.declarations.filter { $0.kind == .struct }
        #expect(structs.count == 1)
        #expect(structs[0].name == "MyView")
        #expect(structs[0].accessLevel == "public")
        #expect(structs[0].inheritedTypes == ["View"])
    }

    @Test("Extracts class with attributes")
    func classWithAttributes() {
        let result = extract("""
        @MainActor @Observable
        final class HomeViewModel {
            var items: [String] = []
        }
        """)

        let classes = result.declarations.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "HomeViewModel")
        #expect(classes[0].attributes.contains("@MainActor"))
        #expect(classes[0].attributes.contains("@Observable"))
        #expect(classes[0].modifiers.contains("final"))
    }

    @Test("Extracts protocol")
    func protocolDecl() {
        let result = extract("""
        public protocol VODQuerying: Sendable {
            func movies() async throws -> [Movie]
        }
        """)

        let protocols = result.declarations.filter { $0.kind == .protocol }
        #expect(protocols.count == 1)
        #expect(protocols[0].name == "VODQuerying")
        #expect(protocols[0].inheritedTypes == ["Sendable"])

        let functions = result.declarations.filter { $0.kind == .function }
        #expect(functions.count == 1)
        #expect(functions[0].name == "movies")
        #expect(functions[0].parent == "VODQuerying")
    }

    @Test("Extracts enum with cases")
    func enumDecl() {
        let result = extract("""
        enum ContentType: String, Codable {
            case movie
            case series
            case channel
        }
        """)

        let enums = result.declarations.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "ContentType")

        let cases = result.declarations.filter { $0.kind == .enumCase }
        #expect(cases.count == 3)
        #expect(cases.map(\.name).contains("movie"))
    }

    @Test("Extracts extension with conformance")
    func extensionDecl() {
        let result = extract("""
        extension MyView: Equatable {
            static func == (lhs: Self, rhs: Self) -> Bool { true }
        }
        """)

        let extensions = result.declarations.filter { $0.kind == .extension }
        #expect(extensions.count == 1)
        #expect(extensions[0].name == "MyView")
        #expect(extensions[0].inheritedTypes == ["Equatable"])
    }

    @Test("Extracts actor")
    func actorDecl() {
        let result = extract("""
        actor IndexingCoordinator {
            private let db: GraphDatabase
            func index() async throws { }
        }
        """)

        let actors = result.declarations.filter { $0.kind == .actor }
        #expect(actors.count == 1)
        #expect(actors[0].name == "IndexingCoordinator")
    }

    @Test("Extracts function signature")
    func functionSignature() {
        let result = extract("""
        struct S {
            func fetch(query: String, limit: Int) async throws -> [Result] { [] }
        }
        """)

        let functions = result.declarations.filter { $0.kind == .function }
        #expect(functions.count == 1)
        let sig = functions[0].signature ?? "nil"
        #expect(sig.contains("query"), "Signature was: \(sig)")
        #expect(sig.contains("limit"), "Signature was: \(sig)")
        #expect(sig.contains("->"), "Signature was: \(sig)")
    }

    @Test("Extracts initializer")
    func initDecl() {
        let result = extract("""
        struct Config {
            init(path: String, debug: Bool = false) { }
        }
        """)

        let inits = result.declarations.filter { $0.kind == .initializer }
        #expect(inits.count == 1)
        let initSig = inits[0].signature ?? "nil"
        #expect(initSig.contains("path"), "Init signature was: \(initSig)")
    }

    @Test("Extracts nested types")
    func nestedTypes() {
        let result = extract("""
        struct Outer {
            struct Inner {
                var value: Int
            }
        }
        """)

        let inner = result.declarations.first { $0.name == "Inner" }
        #expect(inner?.parent == "Outer")
    }

    @Test("Extracts doc comments")
    func docComments() {
        let result = extract("""
        /// This is a documented type.
        struct Documented { }
        """)

        let doc = result.declarations.first { $0.name == "Documented" }
        #expect(doc?.documentation == "This is a documented type.")
    }
}
