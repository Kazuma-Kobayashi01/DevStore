import Foundation

public struct AttachedImage: Sendable {
    public var imagePath: String
    public var mountPoints: [String]
}

public struct VolumeInfo: Sendable {
    public var volumeUUID: String
    public var volumeName: String
    public var writable: Bool
}

public enum DiskImageError: Error, CustomStringConvertible {
    case command(String, ShellResult)
    case notMounted(String)

    public var description: String {
        switch self {
        case let .command(what, r): "\(what) failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .notMounted(p): "\(p) is not a mount point"
        }
    }
}

/// Thin wrapper over hdiutil/diskutil. Never forces a detach.
public enum DiskImage {
    public static func attachedImages() throws -> [AttachedImage] {
        let r = try Shell.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard r.status == 0 else { throw DiskImageError.command("hdiutil info", r) }
        let plist = try PropertyListSerialization.propertyList(from: r.stdoutData, format: nil) as? [String: Any]
        let images = plist?["images"] as? [[String: Any]] ?? []
        return images.map { img in
            let entities = img["system-entities"] as? [[String: Any]] ?? []
            return AttachedImage(imagePath: img["image-path"] as? String ?? "",
                                 mountPoints: entities.compactMap { $0["mount-point"] as? String })
        }
    }

    public static func volumeInfo(mountPoint: String) throws -> VolumeInfo {
        let r = try Shell.run("/usr/sbin/diskutil", ["info", "-plist", mountPoint])
        guard r.status == 0 else { throw DiskImageError.command("diskutil info", r) }
        let d = try PropertyListSerialization.propertyList(from: r.stdoutData, format: nil) as? [String: Any] ?? [:]
        return VolumeInfo(volumeUUID: d["VolumeUUID"] as? String ?? "",
                          volumeName: d["VolumeName"] as? String ?? "",
                          writable: d["WritableVolume"] as? Bool ?? false)
    }

    /// Volume UUIDs of every volume mounted from an attached disk image.
    public static func mountedImageVolumeUUIDs() throws -> [String: String] {
        var result: [String: String] = [:]
        for img in try attachedImages() {
            for mp in img.mountPoints {
                if let info = try? volumeInfo(mountPoint: mp) { result[info.volumeUUID] = mp }
            }
        }
        return result
    }

    public static func attach(bundle: String, mountPoint: String, readOnly: Bool = false) throws {
        var args = ["attach", "-nobrowse", "-owners", "on", "-mountpoint", mountPoint]
        if readOnly { args.append("-readonly") }
        args.append(bundle)
        let r = try Shell.run("/usr/bin/hdiutil", args)
        guard r.status == 0 else { throw DiskImageError.command("hdiutil attach", r) }
    }

    public static func detach(mountPoint: String) throws {
        guard isMountPoint(mountPoint) else { throw DiskImageError.notMounted(mountPoint) }
        _ = try Shell.run("/bin/sync", [])
        let r = try Shell.run("/usr/bin/hdiutil", ["detach", mountPoint])
        guard r.status == 0 else { throw DiskImageError.command("hdiutil detach (not forced; volume busy?)", r) }
    }

    public static func isMountPoint(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let mounted = withUnsafeBytes(of: &s.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mounted == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func isSparseBundle(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return path.hasSuffix(".sparsebundle")
            && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
            && FileManager.default.fileExists(atPath: path + "/Info.plist")
    }

    /// APFS clone of a bundle directory (copy-on-write; shares storage with the source).
    public static func cloneBundle(from source: String, to destination: String) throws {
        let r = try Shell.run("/bin/cp", ["-c", "-R", source, destination])
        guard r.status == 0 else { throw DiskImageError.command("cp -c", r) }
    }

    public static func allocatedBytes(_ path: String) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(atPath: path)
        while let rel = e?.nextObject() as? String {
            var st = stat()
            if lstat(path + "/" + rel, &st) == 0 { total += Int64(st.st_blocks) * 512 }
        }
        return total
    }
}
