/// The complete extraction result from parsing a single Swift file.
public struct FileExtractionResult: Sendable {
    public let filePath: String
    public var declarations: [ExtractedDeclaration] = []
    public var imports: [ExtractedImport] = []
    public var wrapperUsages: [ExtractedWrapperUsage] = []
    public var viewCompositions: [ExtractedViewComposition] = []
    public var environmentUsages: [ExtractedEnvironmentUsage] = []
    public var environmentDeclarations: [ExtractedEnvironmentDeclaration] = []
    public var environmentInjections: [ExtractedEnvironmentInjection] = []
    public var typeReferences: [ExtractedTypeReference] = []
    public var functionCalls: [ExtractedFunctionCall] = []

    public init(filePath: String) {
        self.filePath = filePath
    }
}

/// A declaration extracted from source.
public struct ExtractedDeclaration: Sendable {
    public let kind: NodeKind
    public let name: String
    public let line: Int
    public let column: Int
    public let endLine: Int?
    public let accessLevel: String?
    public let attributes: [String]
    public let modifiers: [String]
    public let inheritedTypes: [String]
    public let signature: String?
    public let documentation: String?
    /// For nested declarations, the parent's name.
    public let parent: String?
    /// Members of this declaration (for types).
    public var members: [ExtractedDeclaration]

    public init(
        kind: NodeKind, name: String,
        line: Int, column: Int, endLine: Int? = nil,
        accessLevel: String? = nil,
        attributes: [String] = [], modifiers: [String] = [],
        inheritedTypes: [String] = [], signature: String? = nil,
        documentation: String? = nil, parent: String? = nil,
        members: [ExtractedDeclaration] = []
    ) {
        self.kind = kind
        self.name = name
        self.line = line
        self.column = column
        self.endLine = endLine
        self.accessLevel = accessLevel
        self.attributes = attributes
        self.modifiers = modifiers
        self.inheritedTypes = inheritedTypes
        self.signature = signature
        self.documentation = documentation
        self.parent = parent
        self.members = members
    }
}

/// An import statement.
public struct ExtractedImport: Sendable {
    public let moduleName: String
    public let isTestable: Bool
    public let line: Int

    public init(moduleName: String, isTestable: Bool, line: Int) {
        self.moduleName = moduleName
        self.isTestable = isTestable
        self.line = line
    }
}

/// A property wrapper usage.
public struct ExtractedWrapperUsage: Sendable {
    public let wrapperName: String   // e.g. "State", "Environment", "Observable"
    public let argument: String?     // e.g. "\.profileManager"
    public let propertyName: String
    public let line: Int

    public init(wrapperName: String, argument: String?, propertyName: String, line: Int) {
        self.wrapperName = wrapperName
        self.argument = argument
        self.propertyName = propertyName
        self.line = line
    }
}

/// A SwiftUI view composition (parent view → child view).
public struct ExtractedViewComposition: Sendable {
    public let parentView: String
    public let childView: String
    public let line: Int
    /// Conditional context, e.g. "conditional", "ForEach", "case .loading"
    public let context: String?

    public init(parentView: String, childView: String, line: Int, context: String? = nil) {
        self.parentView = parentView
        self.childView = childView
        self.line = line
        self.context = context
    }
}

/// A usage of @Environment in a view.
public struct ExtractedEnvironmentUsage: Sendable {
    public let viewName: String
    public let keyPath: String  // e.g. "\.profileManager"
    public let propertyName: String
    public let line: Int

    public init(viewName: String, keyPath: String, propertyName: String, line: Int) {
        self.viewName = viewName
        self.keyPath = keyPath
        self.propertyName = propertyName
        self.line = line
    }
}

/// A .environment() modifier injection in a view body.
public struct ExtractedEnvironmentInjection: Sendable {
    public let viewName: String        // The view providing the injection
    public let keyPath: String         // e.g., "\.appServices" or "AppServices.self"
    public let line: Int

    public init(viewName: String, keyPath: String, line: Int) {
        self.viewName = viewName
        self.keyPath = keyPath
        self.line = line
    }
}

/// A type reference from a containing symbol to a referenced type.
public struct ExtractedTypeReference: Sendable {
    public let containingSymbol: String      // Enclosing type name (e.g., "MovieDetailView")
    public let referencedTypeName: String    // Referenced type (e.g., "Movie")
    public let line: Int

    public init(containingSymbol: String, referencedTypeName: String, line: Int) {
        self.containingSymbol = containingSymbol
        self.referencedTypeName = referencedTypeName
        self.line = line
    }
}

/// The kind of function call detected.
public enum CallKind: String, Sendable {
    case selfCall      // self.method() or implicit self
    case superCall     // super.method()
    case staticCall    // TypeName.method() or TypeName.shared.method()
    case instanceCall  // variable.method()
    case initCall      // TypeName() constructor
    case freeCall      // top-level free function
}

/// A function/method call extracted from source.
public struct ExtractedFunctionCall: Sendable {
    public let callerName: String        // The calling function name
    public let callerParent: String?     // Enclosing type of the caller
    public let calleeName: String        // The called function name
    public let receiverType: String?     // The type of the receiver (if known)
    public let kind: CallKind            // How the call was made
    public let line: Int
    public let column: Int

    public init(
        callerName: String, callerParent: String?,
        calleeName: String, receiverType: String?,
        kind: CallKind, line: Int, column: Int
    ) {
        self.callerName = callerName
        self.callerParent = callerParent
        self.calleeName = calleeName
        self.receiverType = receiverType
        self.kind = kind
        self.line = line
        self.column = column
    }
}

/// An EnvironmentKey declaration.
public struct ExtractedEnvironmentDeclaration: Sendable {
    public let keyName: String     // e.g. "profileManager"
    public let valueType: String?  // e.g. "ProfileManager"
    public let typeName: String    // The conforming type name
    public let line: Int

    public init(keyName: String, valueType: String?, typeName: String, line: Int) {
        self.keyName = keyName
        self.valueType = valueType
        self.typeName = typeName
        self.line = line
    }
}
