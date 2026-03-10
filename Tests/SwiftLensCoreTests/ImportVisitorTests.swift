import Testing
@testable import SwiftLensCore

@Suite("ImportVisitor")
struct ImportVisitorTests {

    private func extract(_ source: String) -> FileExtractionResult {
        SwiftFileIndexer().index(source: source, filePath: "/test.swift")
    }

    @Test("Extracts import statements")
    func basicImports() {
        let result = extract("""
        import Foundation
        import SwiftUI
        """)

        #expect(result.imports.count == 2)
        #expect(result.imports[0].moduleName == "Foundation")
        #expect(result.imports[0].isTestable == false)
        #expect(result.imports[1].moduleName == "SwiftUI")
    }

    @Test("Detects @testable imports")
    func testableImport() {
        let result = extract("""
        @testable import MyModule
        import Foundation
        """)

        let testable = result.imports.first { $0.moduleName == "MyModule" }
        #expect(testable?.isTestable == true)

        let foundation = result.imports.first { $0.moduleName == "Foundation" }
        #expect(foundation?.isTestable == false)
    }
}
