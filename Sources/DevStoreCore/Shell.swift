import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var stdoutData: Data
}

public enum Shell {
    /// Runs a program with captured output. Output goes through temporary files so large
    /// output cannot deadlock on a full pipe.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: String? = nil) throws -> ShellResult {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("devstore-\(newId())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("out")
        let errURL = dir.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        try out.close()
        try err.close()
        let o = try Data(contentsOf: outURL)
        let e = try Data(contentsOf: errURL)
        return ShellResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                           stderr: String(decoding: e, as: UTF8.self), stdoutData: o)
    }

    /// Runs with the caller's stdin/stdout/stderr; returns the exit status.
    public static func runInheriting(_ executable: String, _ arguments: [String],
                                     environment: [String: String],
                                     currentDirectory: String? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        if let currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
