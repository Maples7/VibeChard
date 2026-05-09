import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Filesystem operations VibeChard cares about. Kept narrow on purpose so
/// unit tests can substitute an in-memory implementation without
/// reimplementing all of `FileManager`.
public protocol FileSystem: Sendable {
    func fileExists(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool

    /// Recursively create the directory if needed. No-op if it exists.
    func createDirectory(at path: String) throws

    func readFile(at path: String) throws -> Data

    /// Atomic write: writes to a sibling tempfile and renames into place.
    func writeFileAtomic(_ data: Data, to path: String) throws

    func removeItem(at path: String) throws

    /// Returns the destination of a symbolic link, or nil if `path`
    /// either doesn't exist or isn't a symlink.
    func symlinkDestination(at path: String) -> String?

    /// Idempotently ensure `linkPath` is a symlink pointing to
    /// `destination`. If `linkPath` already exists pointing elsewhere,
    /// it is replaced. If a non-symlink already occupies the path,
    /// throws.
    func createSymbolicLink(at linkPath: String, withDestination destination: String) throws

    /// Copy a file (or symlink) from `source` to `destination`,
    /// preserving permissions and symlink semantics (symlinks are
    /// copied as-is, not followed). Parent of `destination` must
    /// already exist. Throws if `destination` already exists.
    func copyItem(from source: String, to destination: String) throws

    /// Recursively clone `source` to `destination` using APFS
    /// `clonefile(2)` so the dest is a copy-on-write view of the
    /// source. Used by `vch new --seed-spm-from <task>` (#55) to
    /// reuse a sibling task's SwiftPM bare-mirror cache without
    /// double-paying the disk. The destination must NOT exist; the
    /// parent directory of `destination` must exist. On non-APFS
    /// volumes or unsupported filesystems the call throws so callers
    /// can surface a clear error rather than silently fall back.
    func cloneItem(from source: String, to destination: String) throws
}

/// Production implementation backed by `FileManager`.
public struct DiskFileSystem: FileSystem {
    public init() {}

    public func fileExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    public func directoryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    public func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
    }

    public func readFile(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeFileAtomic(_ data: Data, to path: String) throws {
        let dest = URL(fileURLWithPath: path)
        let parent = dest.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        // Atomic via .atomic flag: Foundation writes to a temp and renames.
        try data.write(to: dest, options: .atomic)
    }

    public func removeItem(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func symlinkDestination(at path: String) -> String? {
        // `destinationOfSymbolicLink` throws if `path` is not a symlink
        // or doesn't exist; callers want a simple "is it a link to X" check.
        return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    public func createSymbolicLink(at linkPath: String, withDestination destination: String) throws {
        let fm = FileManager.default
        // Idempotent: if the symlink already points at `destination`,
        // we're done. Otherwise, replace it.
        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            if existing == destination { return }
            try fm.removeItem(atPath: linkPath)
        } else if fm.fileExists(atPath: linkPath) {
            // Path is occupied by a regular file/dir. Refuse — vch
            // should not silently delete user data.
            throw VibeChardError.externalCommandFailed(
                cmd: "createSymbolicLink",
                exitCode: 17,
                stderr: "non-symlink already exists at \(linkPath)"
            )
        }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: destination)
    }

    public func copyItem(from source: String, to destination: String) throws {
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    public func cloneItem(from source: String, to destination: String) throws {
        // `clonefile(2)` requires the destination to NOT exist. Bail
        // early with a clear error rather than letting Darwin
        // surface a less informative EEXIST.
        if fileExists(at: destination) || directoryExists(at: destination) {
            throw VibeChardError.externalCommandFailed(
                cmd: "clonefile",
                exitCode: Int32(EEXIST),
                stderr: "destination already exists at \(destination)"
            )
        }
        let result = source.withCString { src in
            destination.withCString { dst in
                clonefile(src, dst, 0)
            }
        }
        if result != 0 {
            let savedErrno = errno
            let message = String(cString: strerror(savedErrno))
            throw VibeChardError.externalCommandFailed(
                cmd: "clonefile \(source) \(destination)",
                exitCode: savedErrno,
                stderr: message
            )
        }
    }
}
