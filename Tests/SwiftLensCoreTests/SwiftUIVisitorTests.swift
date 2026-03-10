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

    @Test("Only detects composition inside body")
    func onlyInsideBody() {
        let result = extract("""
        struct MyView: View {
            func helperView() -> some View {
                HelperChild()
            }
            var body: some View {
                BodyChild()
            }
        }
        """)

        let compositions = result.viewCompositions
        // Only BodyChild should be detected (inside body)
        #expect(compositions.contains { $0.childView == "BodyChild" })
        // HelperChild is NOT inside body
        #expect(!compositions.contains { $0.childView == "HelperChild" })
    }
}
