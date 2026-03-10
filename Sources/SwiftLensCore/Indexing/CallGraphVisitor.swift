import SwiftSyntax

/// Extracts function/method calls from Swift syntax for building call graph edges.
///
/// Detects four categories of calls:
/// 1. `self.method()` — resolved via enclosing type
/// 2. `TypeName.staticMethod()` / `TypeName.shared.method()` — explicit type
/// 3. Free function calls — `helperFunc()`
/// 4. Calls on typed variables — `let vm: HomeViewModel` → `vm.load()` (best-effort)
final class CallGraphVisitor: SyntaxVisitor {
    var functionCalls: [ExtractedFunctionCall] = []

    private let converter: SourceLocationConverter

    /// Stack tracking the current enclosing function/method/initializer.
    private var callerStack: [CallerContext] = []

    /// Stack tracking the current enclosing type.
    private var typeStack: [String] = []

    /// Map of local variable names to their type annotations within current scope.
    /// Cleared when entering/exiting function bodies.
    private var localTypeAnnotations: [String: String] = [:]

    /// Swift standard library and common framework free functions to skip.
    private static let builtinFunctions: Set<String> = [
        "print", "debugPrint", "dump", "fatalError", "preconditionFailure",
        "precondition", "assert", "assertionFailure",
        "min", "max", "abs", "zip", "stride", "type",
        "withAnimation", "withTransaction", "withTaskGroup",
        "withThrowingTaskGroup", "withCheckedContinuation",
        "withCheckedThrowingContinuation", "withUnsafeContinuation",
        "withUnsafeThrowingContinuation",
        "DispatchQueue", "NotificationCenter", "UserDefaults",
    ]

    private struct CallerContext {
        let name: String       // Function name
        let parent: String?    // Enclosing type name
    }

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Type context tracking

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { typeStack.removeLast() }

    // MARK: - Function context tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        callerStack.append(CallerContext(name: node.name.text, parent: typeStack.last))
        localTypeAnnotations = [:]
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        callerStack.removeLast()
        localTypeAnnotations = [:]
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let failable = node.optionalMark?.text ?? ""
        callerStack.append(CallerContext(name: "init" + failable, parent: typeStack.last))
        localTypeAnnotations = [:]
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        callerStack.removeLast()
        localTypeAnnotations = [:]
    }

    // MARK: - Local type annotations (for receiver type resolution)

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Only track local variables (inside a function)
        guard !callerStack.isEmpty else { return .visitChildren }

        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
               let typeAnnotation = binding.typeAnnotation?.type.trimmedDescription {
                localTypeAnnotations[name] = typeAnnotation
            }
        }
        return .visitChildren
    }

    // MARK: - Call detection

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let caller = callerStack.last else { return .visitChildren }

        let callerName = caller.name
        let callerParent = caller.parent

        // Analyze the called expression to determine what's being called
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            // Method call: something.method()
            let methodName = memberAccess.declName.baseName.text
            handleMemberCall(
                memberAccess: memberAccess,
                methodName: methodName,
                callerName: callerName,
                callerParent: callerParent,
                node: node
            )
        } else if let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            // Direct call: functionName() or TypeName()
            let name = declRef.baseName.text
            handleDirectCall(
                name: name,
                callerName: callerName,
                callerParent: callerParent,
                node: node
            )
        }

        return .visitChildren
    }

    // MARK: - Call analysis helpers

    private func handleMemberCall(
        memberAccess: MemberAccessExprSyntax,
        methodName: String,
        callerName: String,
        callerParent: String?,
        node: FunctionCallExprSyntax
    ) {
        // Skip common non-interesting calls
        guard !isChainableModifier(methodName) else { return }

        let location = node.startLocation(converter: converter)

        if let base = memberAccess.base {
            if let selfExpr = base.as(DeclReferenceExprSyntax.self) {
                let baseName = selfExpr.baseName.text
                if baseName == "self" || baseName == "Self" {
                    // self.method() → call within same type
                    recordCall(
                        callerName: callerName,
                        callerParent: callerParent,
                        calleeName: methodName,
                        receiverType: callerParent,
                        kind: .selfCall,
                        line: location.line,
                        column: location.column
                    )
                    return
                }

                if baseName == "super" {
                    // super.method() → call to superclass
                    recordCall(
                        callerName: callerName,
                        callerParent: callerParent,
                        calleeName: methodName,
                        receiverType: nil,
                        kind: .superCall,
                        line: location.line,
                        column: location.column
                    )
                    return
                }

                if baseName.first?.isUppercase == true {
                    // TypeName.method() → static call
                    recordCall(
                        callerName: callerName,
                        callerParent: callerParent,
                        calleeName: methodName,
                        receiverType: baseName,
                        kind: .staticCall,
                        line: location.line,
                        column: location.column
                    )
                    return
                }

                // variable.method() → check local type annotations
                if let typeName = localTypeAnnotations[baseName] {
                    let cleanType = typeName.replacingOccurrences(of: "?", with: "")
                        .replacingOccurrences(of: "!", with: "")
                    recordCall(
                        callerName: callerName,
                        callerParent: callerParent,
                        calleeName: methodName,
                        receiverType: cleanType,
                        kind: .instanceCall,
                        line: location.line,
                        column: location.column
                    )
                    return
                }

                // variable.method() without type info — still record with variable name
                recordCall(
                    callerName: callerName,
                    callerParent: callerParent,
                    calleeName: methodName,
                    receiverType: nil,
                    kind: .instanceCall,
                    line: location.line,
                    column: location.column
                )
                return
            }

            // Chained access: something.property.method() or Type.shared.method()
            if let innerMember = base.as(MemberAccessExprSyntax.self) {
                if let innerBase = innerMember.base?.as(DeclReferenceExprSyntax.self) {
                    let baseName = innerBase.baseName.text
                    if baseName.first?.isUppercase == true {
                        // Type.something.method() → static/singleton call
                        recordCall(
                            callerName: callerName,
                            callerParent: callerParent,
                            calleeName: methodName,
                            receiverType: baseName,
                            kind: .staticCall,
                            line: location.line,
                            column: location.column
                        )
                        return
                    }
                }
            }
        }

        // Fallback: record the call without receiver type info
        recordCall(
            callerName: callerName,
            callerParent: callerParent,
            calleeName: methodName,
            receiverType: nil,
            kind: .instanceCall,
            line: location.line,
            column: location.column
        )
    }

    private func handleDirectCall(
        name: String,
        callerName: String,
        callerParent: String?,
        node: FunctionCallExprSyntax
    ) {
        guard !Self.builtinFunctions.contains(name) else { return }

        let location = node.startLocation(converter: converter)

        if name.first?.isUppercase == true {
            // TypeName() → initializer call, already handled by TypeReferenceVisitor
            // But record as a call edge too for call graph completeness
            recordCall(
                callerName: callerName,
                callerParent: callerParent,
                calleeName: "init",
                receiverType: name,
                kind: .initCall,
                line: location.line,
                column: location.column
            )
        } else {
            // Free function or method call without explicit receiver
            // Could be: local function, top-level function, or implicit self.method()
            if callerParent != nil {
                // Inside a type — could be implicit self call
                recordCall(
                    callerName: callerName,
                    callerParent: callerParent,
                    calleeName: name,
                    receiverType: callerParent,
                    kind: .selfCall,
                    line: location.line,
                    column: location.column
                )
            } else {
                // Top-level — free function call
                recordCall(
                    callerName: callerName,
                    callerParent: callerParent,
                    calleeName: name,
                    receiverType: nil,
                    kind: .freeCall,
                    line: location.line,
                    column: location.column
                )
            }
        }
    }

    private func recordCall(
        callerName: String,
        callerParent: String?,
        calleeName: String,
        receiverType: String?,
        kind: CallKind,
        line: Int,
        column: Int
    ) {
        functionCalls.append(ExtractedFunctionCall(
            callerName: callerName,
            callerParent: callerParent,
            calleeName: calleeName,
            receiverType: receiverType,
            kind: kind,
            line: line,
            column: column
        ))
    }

    /// Skip SwiftUI view modifiers and common chainable methods that aren't
    /// interesting for call graph analysis.
    private func isChainableModifier(_ name: String) -> Bool {
        Self.modifierNames.contains(name)
    }

    private static let modifierNames: Set<String> = [
        // SwiftUI layout
        "frame", "padding", "offset", "position",
        "background", "overlay", "border", "cornerRadius",
        "clipShape", "clipped", "mask",
        // SwiftUI appearance
        "foregroundColor", "foregroundStyle", "font", "opacity",
        "shadow", "blur", "brightness", "contrast", "saturation",
        "tint", "accentColor",
        // SwiftUI sizing
        "fixedSize", "layoutPriority", "aspectRatio",
        "scaleEffect", "rotationEffect",
        // SwiftUI interaction
        "onTapGesture", "onLongPressGesture", "gesture",
        "disabled", "allowsHitTesting",
        // SwiftUI navigation
        "navigationTitle", "navigationBarTitleDisplayMode",
        "navigationDestination", "sheet", "fullScreenCover",
        "popover", "alert", "confirmationDialog",
        // SwiftUI list/scroll
        "listStyle", "listRowBackground", "listRowSeparator",
        "scrollIndicators", "scrollContentBackground",
        // SwiftUI other
        "onAppear", "onDisappear", "task", "onChange",
        "environment", "environmentObject",
        "id", "tag", "accessibilityLabel", "accessibilityHint",
        "animation", "transition", "withAnimation",
        "toolbar", "toolbarItem",
        // Common Combine/async
        "sink", "receive", "map", "flatMap", "compactMap",
        "filter", "reduce", "catch", "retry", "eraseToAnyPublisher",
        // Collection operations (not interesting for call graphs)
        "append", "insert", "remove", "removeAll", "contains",
        "sorted", "reversed", "enumerated", "joined",
        "first", "last", "prefix", "suffix", "dropFirst", "dropLast",
        "forEach", "isEmpty",
    ]
}
