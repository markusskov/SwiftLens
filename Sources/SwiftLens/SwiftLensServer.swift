import MCP
import SwiftLensCore
import Foundation

/// Main MCP server for SwiftLens.
@main
struct SwiftLensServer {
    static func main() async throws {
        // Parse command-line arguments
        let args = CommandLine.arguments
        var projectPath = FileManager.default.currentDirectoryPath

        if let projectIdx = args.firstIndex(of: "--project"),
           projectIdx + 1 < args.count {
            let rawPath = args[projectIdx + 1]
            if rawPath == "." {
                projectPath = FileManager.default.currentDirectoryPath
            } else if rawPath.hasPrefix("~") {
                projectPath = (rawPath as NSString).expandingTildeInPath
            } else {
                projectPath = rawPath
            }
        }

        // Resolve to absolute path
        projectPath = (projectPath as NSString).standardizingPath

        // Load optional config
        let configParser = ConfigParser()
        let config = configParser.parse(projectRoot: projectPath)

        // Open database
        let dbPath = DatabasePath.forProject(rootPath: projectPath)
        let db = try GraphDatabase(path: dbPath)

        // Create coordinator and run initial index
        let coordinator = IndexingCoordinator(db: db)
        let result = try await coordinator.index(
            projectRoot: projectPath,
            config: config
        )

        // Log to stderr (stdout is for MCP protocol)
        FileHandle.standardError.write(
            Data("[SwiftLens] Indexed \(result.totalFiles) files (\(result.indexedFiles) changed) in \(result.modules) modules\n".utf8)
        )

        let queryEngine = QueryEngine(db: db)

        let handlers = ToolHandlers(
            queryEngine: queryEngine,
            indexingCoordinator: coordinator,
            projectId: result.projectId,
            projectRoot: projectPath,
            projectConfig: config
        )

        // Create MCP server
        let server = Server(
            name: "swift-lens",
            version: "1.0.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        // Register handlers (actor-isolated, so use await)
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolDefinitions.allTools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await handlers.handle(params)
        }

        // Start server on stdio
        let transport = StdioTransport()
        try await server.start(transport: transport)

        FileHandle.standardError.write(
            Data("[SwiftLens] MCP server started on stdio\n".utf8)
        )

        // Run until stopped
        await server.waitUntilCompleted()
    }
}
