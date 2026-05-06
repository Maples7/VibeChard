import Foundation

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
}
