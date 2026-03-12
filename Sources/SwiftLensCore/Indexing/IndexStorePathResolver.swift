import Foundation

/// Auto-detect index store and libIndexStore paths for a project.
struct IndexStorePathResolver {

    /// Auto-detect the index store path for an SPM project.
    /// Checks common build directories for the presence of a v5/units directory.
    static func findIndexStorePath(projectRoot: String) -> String? {
        let candidates = [
            "\(projectRoot)/.build/arm64-apple-macosx/debug/index/store",
            "\(projectRoot)/.build/arm64-apple-macosx/release/index/store",
            "\(projectRoot)/.build/x86_64-apple-macosx/debug/index/store",
            "\(projectRoot)/.build/x86_64-apple-macosx/release/index/store",
        ]

        let fm = FileManager.default
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate + "/v5/units", isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }

        // Check Xcode DerivedData for the project
        let derivedDataBase = fm.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/DerivedData").path()
        if fm.fileExists(atPath: derivedDataBase) {
            let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent
            if let contents = try? fm.contentsOfDirectory(atPath: derivedDataBase) {
                for dir in contents where dir.hasPrefix(projectName) {
                    let storePath = derivedDataBase + "/" + dir + "/Index.noindex/DataStore"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: storePath, isDirectory: &isDir), isDir.boolValue {
                        return storePath
                    }
                }
            }
        }

        return nil
    }

    /// Find libIndexStore.dylib path.
    /// Checks CommandLineTools first, then active Xcode toolchain.
    static func findLibIndexStorePath() -> String? {
        let fm = FileManager.default

        // CommandLineTools path
        let cltPath = "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"
        if fm.fileExists(atPath: cltPath) {
            return cltPath
        }

        // Try to find via xcrun (Xcode toolchain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let swiftPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // swift is at .../usr/bin/swift, libIndexStore at .../usr/lib/libIndexStore.dylib
                let toolchainLib = (swiftPath as NSString)
                    .deletingLastPathComponent  // remove "swift"
                    .replacingOccurrences(of: "/bin", with: "/lib")
                let libPath = toolchainLib + "/libIndexStore.dylib"
                if fm.fileExists(atPath: libPath) {
                    return libPath
                }
            }
        } catch {
            // xcrun not available
        }

        return nil
    }
}
