import ArgumentParser
import Foundation
import VibeChardCore

/// Bridge `VibeChardError` to ArgumentParser's exit-code surface. We
/// can't conform to `Swift.Error` *and* override exit code with the
/// existing enum without breaking Core's testability, so we wrap in
/// `ArgumentParser.ExitCode` at the CLI boundary.
enum CLIBridge {
    /// Run `body`, mapping any `VibeChardError` to a stable stderr line
    /// and an `ExitCode` per Q9. Other errors fall through unchanged.
    static func run(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let err as VibeChardError {
            FileHandle.standardError.write(Data("vch: error: \(err)\n".utf8))
            throw ArgumentParser.ExitCode(err.exitCode)
        }
    }

    /// Print to stderr without a trailing newline being suppressed.
    static func eprintln(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
