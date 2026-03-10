import GRDB
import Foundation

// MARK: - Project Record

public struct ProjectRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "projects"

    public var id: Int64?
    public var name: String
    public var rootPath: String
    public var lastIndexed: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Module Record

public struct ModuleRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "modules"

    public var id: Int64?
    public var projectId: Int64
    public var name: String
    public var path: String?
    public var kind: String // "target", "testTarget", "executableTarget", "external"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Module Dependency Record

public struct ModuleDepRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "module_deps"

    public var id: Int64?
    public var moduleId: Int64
    public var dependencyId: Int64

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Symbol Record

public struct SymbolRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "symbols"

    public var id: Int64?
    public var projectId: Int64
    public var moduleId: Int64?
    public var kind: String        // NodeKind raw value
    public var name: String        // Simple name
    public var qualifiedName: String // Module.Type.member
    public var filePath: String?
    public var line: Int?
    public var column: Int?
    public var endLine: Int?
    public var accessLevel: String? // public, internal, private, fileprivate, package, open
    public var attributes: String?  // JSON array of attributes: ["@Observable", "@MainActor"]
    public var modifiers: String?   // JSON array: ["static", "final"]
    public var inheritedTypes: String? // JSON array: ["View", "Sendable"]
    public var signature: String?   // Function signature or property type
    public var documentation: String? // Doc comments
    public var usr: String?         // Unified symbol resolution (future)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Edge Record

public struct EdgeRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "edges"

    public var id: Int64?
    public var projectId: Int64
    public var sourceId: Int64
    public var targetId: Int64
    public var kind: String  // EdgeKind raw value
    public var metadata: String? // JSON for extra info

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - File Hash Record

public struct FileHashRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "file_hashes"

    public var id: Int64?
    public var projectId: Int64
    public var filePath: String
    public var sha256: String
    public var lastIndexed: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Environment Key Record

public struct EnvironmentKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "environment_keys"

    public var id: Int64?
    public var projectId: Int64
    public var keyName: String      // e.g. "profileManager"
    public var valueType: String?   // e.g. "ProfileManager"
    public var declaringSymbolId: Int64?
    public var filePath: String?
    public var line: Int?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Environment Injection Record

public struct EnvironmentInjectionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "environment_injections"

    public var id: Int64?
    public var projectId: Int64
    public var viewSymbolId: Int64
    public var keyPath: String
    public var filePath: String?
    public var line: Int?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Type Reference Record

public struct TypeReferenceRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "type_references"

    public var id: Int64?
    public var projectId: Int64
    public var sourceSymbolId: Int64
    public var referencedTypeName: String
    public var filePath: String?
    public var line: Int?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Wrapper Usage Record

public struct WrapperUsageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "wrapper_usage"

    public var id: Int64?
    public var projectId: Int64
    public var symbolId: Int64      // The property using the wrapper
    public var wrapperName: String  // e.g. "@State", "@Environment"
    public var argument: String?    // e.g. "\.profileManager" for @Environment
    public var filePath: String?
    public var line: Int?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
