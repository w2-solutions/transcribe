import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: client setup")
struct ClientSetupTests {
    static let helper = "/Applications/Liam's Apps/Transcribe.app/Contents/Helpers/transcribe-mcp"
    static let setup = ClientSetup(helperPath: helper, appVersion: "0.1.1")

    @Test func claudeCodeCommandExact() {
        let expected = #"claude mcp remove --scope user transcribe >/dev/null 2>&1; claude mcp add --scope user --transport stdio transcribe -- '/Applications/Liam'\''s Apps/Transcribe.app/Contents/Helpers/transcribe-mcp'"#
        #expect(Self.setup.claudeCodeCommand == expected)
        let command = Self.setup.claudeCodeCommand
        #expect(command.hasPrefix("claude mcp remove --scope user transcribe >/dev/null 2>&1; "))
        #expect(!command.hasSuffix("\n"))
    }

    /// Nothing a client stores holds a secret, a port or any environment.
    @Test func setupHasNoSecretPortOrEnv() {
        let archive = String(decoding: Self.setup.mcpbArchive(), as: UTF8.self)
        for text in [Self.setup.claudeCodeCommand, Self.setup.desktopConfigEntry, Self.setup.mcpbManifest.encodedString, archive] {
            for banned in ["--env", "\"env\"", "TRANSCRIBE_MCP", "user_config", "access_key", "sensitive", "41873", "44729", "47461"] {
                #expect(!text.contains(banned), "\(banned) in \(text.prefix(80))")
            }
        }
        #expect(Self.setup.mcpbManifest["user_config"] == nil)
        #expect(Self.setup.mcpbManifest["server"]?["mcp_config"]?["env"] == nil)
    }

    @Test func manifestVersionFollowsTheApp() {
        #expect(ClientSetup(helperPath: "/x", appVersion: "0.1.1").version == "0.1.1")
        #expect(ClientSetup(helperPath: "/x", appVersion: "2.3").version == "2.3.0")
        #expect(ClientSetup(helperPath: "/x", appVersion: "7").version == "7.0.0")
        for odd in ["", "1.2.3.4", "1.x", "beta", "1..2", "１.0"] {
            #expect(ClientSetup(helperPath: "/x", appVersion: odd).version == "1.0.0", "\(odd)")
        }
    }

    /// The quoted helper path, run through a real shell, comes back unchanged.
    @Test func shellQuotingSurvivesZsh() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "printf %s " + ClientSetup.shellQuoted(Self.helper)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == Self.helper)
    }

    @Test func desktopConfigEntryIsInnerEntryAndParsesWhenWrapped() throws {
        let entry = Self.setup.desktopConfigEntry
        #expect(entry.hasPrefix("\"transcribe\": {\n  \"command\": "))
        #expect(entry.hasSuffix("\n}"))
        let wrapped = try #require(try JSONSerialization.jsonObject(with: Data(("{" + entry + "}").utf8)) as? [String: Any])
        let server = try #require(wrapped["transcribe"] as? [String: Any])
        #expect(server["command"] as? String == Self.helper)
        #expect((server["args"] as? [Any])?.isEmpty == true)
        #expect(Set(server.keys) == ["command", "args"])
    }

    @Test func manifestFields() {
        let m = Self.setup.mcpbManifest
        #expect(m["manifest_version"] == "0.3")
        #expect(m["name"] == "transcribe")
        #expect(m["display_name"] == "Transcribe")
        #expect(m["version"] == "0.1.1")
        #expect(m["server"]?["type"] == "binary")
        #expect(m["server"]?["entry_point"] == "README.md")
        #expect(m["server"]?["mcp_config"] == ["command": .string(Self.helper), "args": []])
        #expect(m["compatibility"]?["platforms"] == ["darwin"])
        #expect(m["tools"]?[0]?["name"] == "list_recordings")
        #expect(m["tools"]?[1]?["name"] == "get_transcript")
        if case .object(let o) = m {
            #expect(Set(o.keys) == ["manifest_version", "name", "display_name", "version", "description", "author", "server",
                                    "tools", "compatibility"])
        } else { Issue.record("manifest is not an object") }
    }

    @Test func helperProblemRules() {
        let home = "/Users/liam"
        func problem(_ path: String, executable: Bool = true) -> HelperProblem? {
            HelperProblem.helperProblem(path: path, isExecutable: executable, homeDirectory: home)
        }
        let tail = "/Transcribe.app/Contents/Helpers/transcribe-mcp"
        #expect(problem("/Applications" + tail) == nil)
        #expect(problem("/Applications/Utilities" + tail) == nil)
        #expect(problem(home + "/Applications" + tail) == nil)
        #expect(HelperProblem.helperProblem(path: home + "/Applications" + tail, isExecutable: true, homeDirectory: home + "/") == nil)
        #expect(problem("/private/var/folders/xy/T/AppTranslocation/5A1B/d" + tail) == .notInApplications)
        #expect(problem("/Volumes/Transcribe" + tail) == .notInApplications)
        #expect(problem(home + "/Library/Developer/Xcode/DerivedData/Transcribe-abc/Build/Products/Debug" + tail) == .notInApplications)
        #expect(problem(home + "/Downloads" + tail) == .notInApplications)
        #expect(problem("/ApplicationsX" + tail) == .notInApplications)
        #expect(problem("/Applications" + tail, executable: false) == .missing)
    }

    @Test func zipCRCKnownVector() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipWriter.crc32(Data()) == 0)
    }

    @Test func mcpbUnzipsWithManifestAtRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Transcribe for Claude.mcpb")
        try Self.setup.mcpbArchive().write(to: file)

        let (testStatus, testOut) = try Self.run("/usr/bin/unzip", ["-t", file.path])
        #expect(testStatus == 0, "\(testOut)")
        #expect(testOut.contains("No errors detected"))
        let (listStatus, list) = try Self.run("/usr/bin/unzip", ["-Z1", file.path])
        #expect(listStatus == 0)
        #expect(list.split(separator: "\n").map(String.init) == ["manifest.json", "README.md"])

        let (catStatus, manifest) = try Self.run("/usr/bin/unzip", ["-p", file.path, "manifest.json"])
        #expect(catStatus == 0)
        let parsed = try JSONValue.decode(Data(manifest.utf8))
        #expect(parsed == Self.setup.mcpbManifest)
        let (_, readme) = try Self.run("/usr/bin/unzip", ["-p", file.path, "README.md"])
        #expect(readme == ClientSetup.readme + "\n")
    }

    static func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
