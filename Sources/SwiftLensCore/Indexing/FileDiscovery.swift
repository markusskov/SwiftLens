import Foundation

/// Discovers Swift files in a project, respecting exclusion patterns.
public struct FileDiscovery: Sendable {
    /// Default directories to exclude from indexing.
    public static let defaultExclusions: Set<String> = [
        ".build", ".git", "DerivedData", ".swiftpm",
        "Pods", "Carthage", "Build", ".index-build",
    ]

    private let rootPath: String
    private let exclusions: Set<String>
    private let additionalPackages: [String]

    public init(
        rootPath: String,
        exclusions: Set<String> = defaultExclusions,
        additionalPackages: [String] = []
    ) {
        self.rootPath = rootPath
        self.exclusions = exclusions
        self.additionalPackages = additionalPackages
    }

    /// Returns all .swift files under the project root (and additional package paths),
    /// excluding directories matching the exclusion set.
    public func discoverFiles() throws -> [String] {
        var files: [String] = []
        let fm = FileManager.default

        // Collect all roots to scan
        var roots = [rootPath]
        for pkg in additionalPackages {
            let pkgPath = (rootPath as NSString).appendingPathComponent(pkg)
            if fm.fileExists(atPath: pkgPath) {
                roots.append(pkgPath)
            }
        }

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: URL(filePath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let fileName = fileURL.lastPathComponent

                // Skip excluded directories
                if exclusions.contains(fileName) {
                    enumerator.skipDescendants()
                    continue
                }

                // Only include .swift files
                guard fileURL.pathExtension == "swift" else { continue }

                // Verify it's a regular file
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == true
                {
                    files.append(fileURL.path())
                }
            }
        }

        return files.sorted()
    }

    /// Finds all Package.swift files in the project (root + additional packages).
    public func findPackageManifests() throws -> [String] {
        var manifests: [String] = []
        let fm = FileManager.default

        // Check root
        let rootManifest = (rootPath as NSString).appendingPathComponent("Package.swift")
        if fm.fileExists(atPath: rootManifest) {
            manifests.append(rootManifest)
        }

        // Check additional packages
        for pkg in additionalPackages {
            let pkgManifest = (rootPath as NSString)
                .appendingPathComponent(pkg)
                .appending("/Package.swift")
            if fm.fileExists(atPath: pkgManifest) {
                manifests.append(pkgManifest)
            }
        }

        return manifests
    }
}
