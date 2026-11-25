import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: JSON-RPC")
struct JSONRPCTests {
    func parse(_ s: String) -> Result<RPCMessage, RPCError> { RPCMessage.parse(Data(s.utf8)) }

    @Test func parsesRequestWithIntAndStringIDs() throws {
        guard case .success(.request(let id, let method, let params)) =
            parse(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"cursor":"x"}}"#) else {
            Issue.record("not a request"); return
        }
        #expect(id == .int(7) && method == "tools/list" && params?["cursor"] == "x")
        guard case .success(.request(let sid, _, let none)) = parse(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#) else {
            Issue.record("not a request"); return
        }
        #expect(sid == .string("abc") && none == nil)
    }

    @Test func parsesNotification() {
        guard case .success(.notification(let method, _)) = parse(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) else {
            Issue.record("not a notification"); return
        }
        #expect(method == "notifications/initialized")
    }

    @Test func clientResponseIsClassifiedAsResponse() {
        guard case .success(.response(let id)) = parse(#"{"jsonrpc":"2.0","id":3,"result":{}}"#) else {
            Issue.record("not a response"); return
        }
        #expect(id == .int(3))
        guard case .success(.response) = parse(#"{"jsonrpc":"2.0","id":"r","error":{"code":1,"message":"x"}}"#) else {
            Issue.record("error reply not a response"); return
        }
        // A reply with no result or error is not a response.
        guard case .failure(.invalidRequest) = parse(#"{"jsonrpc":"2.0","id":3}"#) else { Issue.record("accepted"); return }
    }

    @Test func invalidJSONIsParseErrorWithNullID() {
        guard case .failure(let e) = parse(#"{"jsonrpc":"2.0","id":1,"#) else { Issue.record("parsed"); return }
        #expect(e == .parse && e.code == -32700)
        let reply = RPCEncode.error(nil, e).json
        #expect(reply["id"] == .null && reply["error"]?["code"] == .int(-32700))
    }

    @Test func arrayBatchIsInvalidRequest() {
        guard case .failure(let e) = parse(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) else { Issue.record("parsed"); return }
        #expect(e == .invalidRequest && e.code == -32600)
        for s in [#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, #"{"id":1,"method":"ping"}"#,
                  #"{"jsonrpc":"2.0","id":1,"method":5}"#, #""text""#, #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#] {
            guard case .failure(.invalidRequest) = parse(s) else { Issue.record("accepted \(s)"); continue }
        }
    }

    @Test func nullIDIsInvalidRequest() {
        guard case .failure(.invalidRequest) = parse(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) else {
            Issue.record("accepted a null id"); return
        }
        guard case .failure(.invalidRequest) = parse(#"{"jsonrpc":"2.0","id":null,"result":{}}"#) else {
            Issue.record("accepted a null-id response"); return
        }
    }

    @Test func encodedResponsesHaveNoNewlines() {
        let text = "line one\nline two\u{2028}three\u{2029}four\r\nfive\u{85}six"
        let data = RPCEncode.result(.int(1), ["content": [["type": "text", "text": .string(text)]]])
        #expect(!data.contains(0x0A) && !data.contains(0x0D))
        #expect(data.json["result"]?["content"]?.arrayValue?.first?["text"]?.string == text)
        #expect(!RPCEncode.error(.string("a\nb"), .methodNotFound).contains(0x0A))
        #expect(!ToolCatalog.tools.encoded().contains(0x0A))
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}
