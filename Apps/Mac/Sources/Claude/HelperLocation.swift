import Foundation
import TranscribeMCP

/// Where this copy's Claude helper is, and whether a setup pointing at it would last (§2.1).
enum HelperLocation {
    /// `Transcribe.app/Contents/Helpers/transcribe-mcp`, the path Claude Code and Claude Desktop run.
    static var url: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/transcribe-mcp").standardizedFileURL }

    static var path: String { url.path(percentEncoded: false) }

    static var problem: HelperProblem? {
        HelperProblem.helperProblem(path: path, isExecutable: FileManager.default.isExecutableFile(atPath: path),
                                    homeDirectory: realHome)
    }

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` is the app's container, so this asks the
    /// user database instead.
    static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "" }
        return String(cString: dir)
    }
}
