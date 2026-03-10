import Foundation

/// Parses optional .swiftlens.yml configuration files.
public struct ConfigParser: Sendable {

    public init() {}

    /// Load project configuration from a .swiftlens.yml file if present.
    public func parse(projectRoot: String) -> ProjectConfig {
        let configPath = (projectRoot as NSString).appendingPathComponent(".swiftlens.yml")

        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return .default
        }

        // Simple YAML parser for our limited schema
        var exclude: Set<String> = []
        var packages: [String] = []

        var currentSection: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("exclude:") {
                currentSection = "exclude"
                continue
            } else if trimmed.hasPrefix("packages:") {
                currentSection = "packages"
                continue
            }

            if trimmed.hasPrefix("- ") {
                let value = trimmed.dropFirst(2)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")

                switch currentSection {
                case "exclude":
                    exclude.insert(value)
                case "packages":
                    packages.append(value)
                default:
                    break
                }
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                currentSection = nil
            }
        }

        return ProjectConfig(exclude: exclude, packages: packages)
    }
}
