import Foundation

/// Locating the sidecar scripts.
///
/// The first version walked up from `CommandLine.arguments[0]`. That breaks the moment the
/// binary is invoked through PATH rather than as `./build/exo`: argv[0] is then the bare
/// name `exo`, `fileURLWithPath` resolves it against the CURRENT DIRECTORY, and walking up
/// two levels lands somewhere arbitrary — in practice `~/tools/iphone.py`.
///
/// `Bundle.main.executablePath` wraps `_NSGetExecutablePath`, which returns the real binary
/// path regardless of how it was invoked, and `resolvingSymlinksInPath` follows a symlink
/// in `~/bin` back to the build directory.
enum Paths {
    static var exeDir: URL {
        if let p = Bundle.main.executablePath, !p.isEmpty {
            return URL(fileURLWithPath: p).resolvingSymlinksInPath().deletingLastPathComponent()
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// Search order: explicit override, then next to the binary, then the usual
    /// build/ -> project-root/tools layout.
    static func tool(_ name: String) -> String? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["EXO_TOOLS"], !override.isEmpty {
            candidates.append((override as NSString).appendingPathComponent(name))
        }
        let d = exeDir
        candidates += [
            d.appendingPathComponent("tools/\(name)").path,                 // exe/tools/x
            d.deletingLastPathComponent().appendingPathComponent("tools/\(name)").path, // exe/../tools/x
            d.deletingLastPathComponent().deletingLastPathComponent()
             .appendingPathComponent("tools/\(name)").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Human-readable failure, since a missing sidecar otherwise surfaces as a bare
    /// Python ENOENT that names a path the user never configured.
    static func missing(_ name: String) -> String {
        """
        could not find tools/\(name)

        Looked next to the binary at:
          \(exeDir.path)
        Set EXO_TOOLS to the directory containing it, e.g.
          EXO_TOOLS=\(NSHomeDirectory())/fun-project/exocortex/exo/tools exo …
        """
    }
}
