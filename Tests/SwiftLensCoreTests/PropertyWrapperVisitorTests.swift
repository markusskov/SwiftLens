import Testing
@testable import SwiftLensCore

@Suite("PropertyWrapperVisitor")
struct PropertyWrapperVisitorTests {

    private func extract(_ source: String) -> FileExtractionResult {
        SwiftFileIndexer().index(source: source, filePath: "/test.swift")
    }

    @Test("Extracts @State wrapper")
    func stateWrapper() {
        let result = extract("""
        struct MyView: View {
            @State var count: Int = 0
            var body: some View { Text("\\(count)") }
        }
        """)

        let wrappers = result.wrapperUsages.filter { $0.wrapperName == "State" }
        #expect(wrappers.count == 1)
        #expect(wrappers[0].propertyName == "count")
    }

    @Test("Extracts @Environment with key path")
    func environmentWrapper() {
        let result = extract("""
        struct MyView: View {
            @Environment(\\.dismiss) var dismiss
            @Environment(\\.profileManager) var profileManager
            var body: some View { Text("Hi") }
        }
        """)

        let envWrappers = result.wrapperUsages.filter { $0.wrapperName == "Environment" }
        #expect(envWrappers.count == 2)

        let dismissWrapper = envWrappers.first { $0.propertyName == "dismiss" }
        #expect(dismissWrapper?.argument == "\\.dismiss")

        // Also check environment usages
        #expect(result.environmentUsages.count == 2)
        #expect(result.environmentUsages[0].viewName == "MyView")
    }

    @Test("Extracts EnvironmentKey declarations")
    func environmentKeyDeclaration() {
        let result = extract("""
        struct ProfileManagerKey: EnvironmentKey {
            static var defaultValue: ProfileManager = ProfileManager()
        }

        extension EnvironmentValues {
            var profileManager: ProfileManager {
                get { self[ProfileManagerKey.self] }
                set { self[ProfileManagerKey.self] = newValue }
            }
        }
        """)

        #expect(result.environmentDeclarations.count >= 1)
        let profileKey = result.environmentDeclarations.first { $0.keyName == "profileManager" }
        #expect(profileKey != nil)
    }
}
