import GRDB
import Foundation

/// Thread-safe SQLite database for the knowledge graph, using WAL mode and connection pooling.
public final class GraphDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    /// Convenience accessor typed as DatabasePool (for read snapshots in production).
    public var dbPool: DatabasePool {
        dbWriter as! DatabasePool
    }

    /// Open (or create) the database at the given path with WAL mode enabled.
    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // WAL mode: readers never block writers
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -8000") // 8MB cache
        }

        // Ensure parent directory exists
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        let pool = try DatabasePool(path: path, configuration: config)
        try GraphSchema.migrator.migrate(pool)
        self.dbWriter = pool
    }

    /// In-memory database for testing.
    public static func inMemory() throws -> GraphDatabase {
        try GraphDatabase(inMemory: ())
    }

    private init(inMemory: Void) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try GraphSchema.migrator.migrate(queue)
        self.dbWriter = queue
    }
}

// MARK: - Database Path Resolution

public enum DatabasePath {
    /// Returns the cache directory path for a project's database.
    /// Uses a hash of the project root path for uniqueness.
    public static func forProject(rootPath: String) -> String {
        let hash = stableHash(rootPath)
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/swift-lens")
            .path()
        return "\(cacheDir)/\(hash).db"
    }

    private static func stableHash(_ string: String) -> String {
        // Simple stable hash using FNV-1a for path→filename mapping
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
