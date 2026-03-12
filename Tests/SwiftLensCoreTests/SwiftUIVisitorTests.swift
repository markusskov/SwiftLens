import Testing
@testable import SwiftLensCore

@Suite("SwiftUIVisitor")
struct SwiftUIVisitorTests {

    private func extract(_ source: String) -> FileExtractionResult {
        SwiftFileIndexer().index(source: source, filePath: "/test.swift")
    }

    @Test("Detects view composition in body")
    func viewComposition() {
        let result = extract("""
        struct ParentView: View {
            var body: some View {
                VStack {
                    HeaderView()
                    ContentView()
                    FooterView()
                }
            }
        }
        """)

        let compositions = result.viewCompositions
        #expect(compositions.count == 4) // VStack + 3 child views
        #expect(compositions.contains { $0.childView == "HeaderView" })
        #expect(compositions.contains { $0.childView == "ContentView" })
        #expect(compositions.contains { $0.childView == "FooterView" })
        #expect(compositions.allSatisfy { $0.parentView == "ParentView" })
    }

    @Test("Ignores non-view types in deny list")
    func denyList() {
        let result = extract("""
        struct MyView: View {
            var body: some View {
                CustomView()
            }
        }
        """)

        // CustomView should be detected, but not Text/Image etc.
        let compositions = result.viewCompositions
        #expect(compositions.contains { $0.childView == "CustomView" })
    }

    @Test("Detects composition in body and View-returning helpers")
    func viewBuilderContexts() {
        let result = extract("""
        struct MyView: View {
            func helperView() -> some View {
                HelperChild()
            }
            func nonViewHelper() -> String {
                NotAView()
                return ""
            }
            var body: some View {
                BodyChild()
            }
        }
        """)

        let compositions = result.viewCompositions
        // BodyChild in body — detected
        #expect(compositions.contains { $0.childView == "BodyChild" })
        // HelperChild in a View-returning function — also detected
        #expect(compositions.contains { $0.childView == "HelperChild" })
        // NotAView in a non-View-returning function — NOT detected
        #expect(!compositions.contains { $0.childView == "NotAView" })
    }
}
