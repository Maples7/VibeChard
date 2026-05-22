import Foundation

/// Explicit xcodebuild project/workspace context. Passing one of these
/// keeps nested Apple projects from being shadowed by a root Package.swift.
public enum XcodebuildContainer: Equatable, Sendable {
    case project(String)
    case workspace(String)

    public static func resolve(
        project: String?,
        workspace: String?
    ) throws -> XcodebuildContainer? {
        let project = normalized(project)
        let workspace = normalized(workspace)
        switch (project, workspace) {
        case let (.some(project), .none):
            return .project(project)
        case let (.none, .some(workspace)):
            return .workspace(workspace)
        case (.none, .none):
            return nil
        case (.some, .some):
            throw VibeChardError.xcodebuildContainerConflict
        }
    }

    public var xcodebuildArguments: [String] {
        switch self {
        case .project(let path):
            return ["-project", path]
        case .workspace(let path):
            return ["-workspace", path]
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}