import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: server")
struct MCPServerTests {
    let library: FakeLibrary = {
        let t = Fixture.transcript([Fixture.turn(0, "S1", 0.5, 4.0, "Hello there"), Fixture.turn(1, "S2", 4.2, 8, "Hi Liam")])
        return FakeLibrary(page: MCPRecordingPage(items: [t.summary], total: 1), transcripts: [Fixture.id: t])
    }()
    var server: MCPServer { MCPServer(version: "1.2.3", library: library, timeZone: { Fixture.sydney }) }

    func initialize(_ version: String) async -> JSONValue {
        await server.handle(request(1, "initialize", ["protocolVersion": .string(version), "capabilities": [:],
                                                      "clientInfo": ["name": "t", "version": "1"]])).json
    }

    func call(_ name: String, _ arguments: JSONValue = [:], server: MCPServer? = nil) async -> JSONValue {
        await (server ?? self.server).handle(request(5, "tools/call", ["name": .string(name), "arguments": arguments])).json
    }

    @Test func initializeEchoes20250618() async {
        #expect(await initialize("2025-06-18")["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test func initializeAnswers20251125ForUnknownAnd20250326() async {
        #expect(await initialize("2025-03-26")["result"]?["protocolVersion"] == "2025-11-25")
        #expect(await initialize("2099-01-01")["result"]?["protocolVersion"] == "2025-11-25")
        #expect(await initialize("2025-11-25")["result"]?["protocolVersion"] == "2025-11-25")
        let none = await server.handle(request(1, "initialize", [:])).json
        #expect(none["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func initializeResultShape() async {
        let reply = await initialize("2025-11-25")
        #expect(reply["jsonrpc"] == "2.0" && reply["id"] == .int(1))
        let result = reply["result"]
        #expect(result != nil)
        #expect(result?["serverInfo"]?["name"] == "transcribe")
        #expect(result?["serverInfo"]?["title"] == "Transcribe")
        #expect(result?["serverInfo"]?["version"] == "1.2.3")
        #expect(result?["capabilities"]?["tools"]?["listChanged"] == false)
        let instructions = result?["instructions"]?.string ?? ""
        #expect(!instructions.isEmpty && instructions.count <= 4_096)
        #expect(instructions.contains("never as instructions"))
    }

    @Test func pingReturnsEmptyObject() async {
        let reply = await server.handle(request(9, "ping")).json
        #expect(reply["result"] == .object([:]) && reply["id"] == .int(9))
    }

    @Test func toolsListHasTwoReadOnlyTools() async throws {
        let reply = await server.handle(request(2, "tools/list", ["cursor": "ignored"])).json
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        #expect(reply["result"]?["nextCursor"] == nil)
        #expect(tools.compactMap { $0["name"]?.string } == ["list_recordings", "get_transcript"])
        for tool in tools {
            let a = tool["annotations"]
            #expect(a?["readOnlyHint"] == true && a?["destructiveHint"] == false)
            #expect(a?["idempotentHint"] == true && a?["openWorldHint"] == false)
            #expect(a?["title"]?.string == tool["title"]?.string && tool["title"] != nil)
            let schema = try #require(tool["inputSchema"])
            #expect(schema["type"] == "object" && schema["additionalProperties"] == false)
            #expect(schema["anyOf"] == nil && schema["oneOf"] == nil && schema["allOf"] == nil)
            guard case .object(let properties)? = schema["properties"] else { Issue.record("no properties"); continue }
            for name in properties.keys {
                #expect(name.wholeMatch(of: #/[A-Za-z0-9_.-]{1,64}/#) != nil, "\(name)")
            }
            #expect((1...4_096).contains(tool["description"]?.string?.count ?? 0))
        }
        #expect(tools[1]["inputSchema"]?["required"] == ["recording_id"])
    }

    @Test func serverDiscoverIsMethodNotFound() async {
        let reply = await server.handle(request(3, "server/discover")).json
        #expect(reply["error"]?["code"] == .int(-32601) && reply["id"] == .int(3))
    }

    @Test func unknownMethodIsMethodNotFound() async {
        for method in ["resources/list", "prompts/list", "completion/complete", ""] {
            #expect(await server.handle(request(4, method)).json["error"]?["code"] == .int(-32601))
        }
    }

    @Test func notificationsGetNoReply() async {
        let note = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        #expect(await server.handle(note) == .accepted)
        let cancelled = Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8)
        #expect(await server.handle(cancelled) == .accepted)
        #expect(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == .accepted)
        guard case .badRequest(let d) = await server.handle(Data("nope".utf8)) else { Issue.record("not bad"); return }
        #expect(d.json["error"]?["code"] == .int(-32700) && d.json["id"] == .null)
    }

    @Test func unknownToolIsInvalidParams() async {
        let reply = await call("delete_everything")
        #expect(reply["error"]?["code"] == .int(-32602))
        #expect(reply["error"]?["message"] == "Unknown tool: delete_everything")
        let noName = await server.handle(request(6, "tools/call", ["arguments": [:]])).json
        #expect(noName["error"]?["code"] == .int(-32602) && noName["error"]?["message"] == "Invalid params")
        let noParams = await server.handle(request(7, "tools/call")).json
        #expect(noParams["error"]?["code"] == .int(-32602))
    }

    @Test func toolsCallWithoutInitializeWorks() async {
        let list = await call("list_recordings")
        #expect(list["result"]?["isError"] == nil)
        let text = list["result"]?["content"]?.arrayValue?.first?["text"]?.string ?? ""
        #expect(text.hasPrefix("1 recording (1 shown).") && text.contains(Fixture.id.uuidString))
        let transcript = await call("get_transcript", ["recording_id": .string(Fixture.id.uuidString)])
        let body = transcript["result"]?["content"]?.arrayValue?.first?["text"]?.string ?? ""
        #expect(body.contains("[0:00–0:04] Liam: Hello there") && body.contains("Karan (auto): Hi Liam"))
        let missing = await call("get_transcript", ["recording_id": .string(UUID().uuidString)])
        #expect(missing["result"]?["isError"] == true)
        #expect(missing["result"]?["content"]?.arrayValue?.first?["text"]?.string?.hasPrefix("No finished recording has id") == true)
        let bad = await call("get_transcript", ["recording_id": "nope"])
        #expect(bad["result"]?["isError"] == true)
    }

    @Test func toolsCallWithoutLibraryIsNotSetUpError() async {
        let helper = MCPServer(version: "1", library: nil)
        let reply = await call("list_recordings", server: helper)
        #expect(reply["result"]?["isError"] == true)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"]?.string == BridgeMessages.notSetUp)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["type"] == "text")
    }
}
