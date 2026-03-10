import Foundation
import CommonCrypto

/// Computes SHA-256 hashes of files for incremental indexing.
public struct FileHasher: Sendable {

    public init() {}

    /// Returns the SHA-256 hex digest of the file at the given path.
    public func hash(filePath: String) throws -> String {
        let data = try Data(contentsOf: URL(filePath: filePath))
        return sha256(data)
    }

    /// SHA-256 hex digest of in-memory data.
    public func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
