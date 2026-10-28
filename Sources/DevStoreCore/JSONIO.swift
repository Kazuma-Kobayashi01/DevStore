import CryptoKit
import Foundation

public enum JSONIO {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public static func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(type, from: url)
    }

    /// Writes to a temporary file in the same directory, then renames over the target.
    public static func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try encoder().encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// Appends one compact JSON object plus newline; the file is append-only.
    public static func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        var data = try encoder(pretty: false).encode(value)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public static func readLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(type, from: Data($0.utf8)) }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Plan {
    /// Digest over the canonical (sorted-key, compact) encoding with an empty digest field.
    public func computedDigest() throws -> String {
        var copy = self
        copy.planDigest = ""
        return "sha256:" + JSONIO.sha256Hex(try JSONIO.encoder(pretty: false).encode(copy))
    }
}
