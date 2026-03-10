import Testing
@testable import SwiftLensCore

@Suite("SPMManifestParser")
struct SPMManifestParserTests {

    @Test("Parses targets from Package.swift source")
    func parseTargets() {
        let source = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(
            name: "MyApp",
            targets: [
                .target(name: "Core", dependencies: []),
                .target(name: "Features", dependencies: ["Core"]),
                .executableTarget(name: "MyApp", dependencies: ["Features", "Core"]),
                .testTarget(name: "CoreTests", dependencies: [.target(name: "Core")]),
            ]
        )
        """

        let parser = SPMManifestParser()
        let targets = parser.parse(source: source)

        // Debug: print target names if count is unexpected
        let names = targets.map(\.name)
        #expect(targets.count == 4, "Expected 4 targets, got \(names)")

        let core = targets.first { $0.name == "Core" }
        #expect(core?.kind == .regular)
        #expect(core?.dependencies.isEmpty == true)

        let features = targets.first { $0.name == "Features" }
        #expect(features?.kind == .regular)
        #expect(features?.dependencies == ["Core"])

        let app = targets.first { $0.name == "MyApp" }
        #expect(app?.kind == .executable)
        #expect(app?.dependencies.contains("Features") == true)
        #expect(app?.dependencies.contains("Core") == true)

        let tests = targets.first { $0.name == "CoreTests" }
        #expect(tests?.kind == .test)
        #expect(tests?.dependencies == ["Core"])
    }

    @Test("Parses product dependencies")
    func parseProductDependencies() {
        let source = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(
            name: "MyApp",
            targets: [
                .target(name: "MyLib", dependencies: [
                    .product(name: "GRDB", package: "GRDB.swift"),
                    "OtherLib",
                ]),
            ]
        )
        """

        let parser = SPMManifestParser()
        let targets = parser.parse(source: source)

        #expect(targets.count == 1)
        let lib = targets.first!
        #expect(lib.dependencies.contains("GRDB"))
        #expect(lib.dependencies.contains("OtherLib"))
    }
}
