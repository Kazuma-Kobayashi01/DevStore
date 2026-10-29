import CryptoKit
import Foundation

/// Incremental SHA-256 for large files.
struct SHA256Stream {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalizeHex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
