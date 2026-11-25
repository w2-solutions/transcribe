import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: HTTP request parser")
struct HTTPRequestParserTests {
    static func raw(_ head: String, body: String = "") -> Data { Data((head + "\r\n\r\n" + body).utf8) }
    static let post = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:41000\r\nContent-Type: application/json"

    func status(_ data: Data) -> Int? {
        if case .reject(let r) = HTTPRequestParser.parse(data) { return r.status }
        return nil
    }

    func request(_ data: Data) throws -> HTTPRequest {
        guard case .request(let r) = HTTPRequestParser.parse(data) else {
            Issue.record("not a request: \(HTTPRequestParser.parse(data))")
            throw CancellationError()
        }
        return r
    }

    @Test func partialNeedsMore() {
        #expect(HTTPRequestParser.parse(Data()) == .needMore)
        #expect(HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nHost: 127".utf8)) == .needMore)
        #expect(HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r".utf8)) == .needMore)
    }

    @Test func headersCompleteReported() {
        let head = Self.post + "\r\nContent-Length: 10"
        let headerBytes = Self.raw(head).count
        #expect(HTTPRequestParser.parse(Self.raw(head, body: "{\"a\":")) == .headersComplete(total: headerBytes + 10))
    }

    @Test func repeatedHeadersJoined() throws {
        let r = try request(Self.raw(Self.post + "\r\nContent-Length: 0\r\nX-A: one\r\nx-a: two\r\nX-A: three"))
        #expect(r.headers["x-a"] == "one, two, three")
    }

    @Test func headersAreCaseInsensitive() throws {
        let r = try request(Self.raw("POST /mcp?x=1 HTTP/1.1\r\nHOST: localhost\r\ncOnTeNt-LeNgTh: 2\r\nX-Thing:   spaced value  ", body: "{}"))
        #expect(r.method == "POST" && r.path == "/mcp")
        #expect(r.headers["host"] == "localhost")
        #expect(r.headers["content-length"] == "2")
        #expect(r.headers["x-thing"] == "spaced value")
    }

    @Test func bodyByContentLength() throws {
        let r = try request(Self.raw(Self.post + "\r\nContent-Length: 17", body: "{\"jsonrpc\":\"2.0\"}"))
        #expect(String(decoding: r.body, as: UTF8.self) == "{\"jsonrpc\":\"2.0\"}")
        let empty = try request(Self.raw(Self.post + "\r\nContent-Length: 0"))
        #expect(empty.body.isEmpty)
        let get = try request(Self.raw("GET /mcp HTTP/1.1\r\nHost: localhost"))
        #expect(get.method == "GET" && get.body.isEmpty)
    }

    @Test func trailingBytesIgnored() throws {
        let r = try request(Self.raw(Self.post + "\r\nContent-Length: 2", body: "{}POST /mcp HTTP/1.1\r\n\r\n"))
        #expect(r.body == Data("{}".utf8))
    }

    @Test func missingContentLength411() {
        #expect(status(Self.raw(Self.post)) == 411)
    }

    @Test func transferEncoding411() {
        #expect(status(Self.raw(Self.post + "\r\nTransfer-Encoding: chunked")) == 411)
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: 2\r\nTransfer-Encoding: identity", body: "{}")) == 411)
    }

    @Test func oversizeHeaders431() {
        let big = Data(("POST /mcp HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 16_400)).utf8)
        #expect(status(big) == 431)
        // Just under the limit is still waiting for more.
        #expect(HTTPRequestParser.parse(Data(("POST /mcp HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 16_000)).utf8)) == .needMore)
    }

    @Test func oversizeBody413() {
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: 1048577")) == 413)
        let head = Self.post + "\r\nContent-Length: 1048576"
        #expect(HTTPRequestParser.parse(Self.raw(head)) == .headersComplete(total: Self.raw(head).count + 1_048_576))
    }

    @Test func garbageRequestLine400() {
        for line in ["post /mcp HTTP/1.1", "POST /mcp HTTP/1.0", "POST  /mcp HTTP/1.1", "POST /mcp", "\u{1}\u{2}",
                     "POSTPOSTPOSTPOSTP /mcp HTTP/1.1", "POST /m\u{7F}cp HTTP/1.1", ""] {
            #expect(status(Self.raw(line + "\r\nContent-Length: 0")) == 400, "\(line)")
        }
    }

    @Test func bareLF400() {
        #expect(status(Data("POST /mcp HTTP/1.1\nHost: localhost\r\n\r\n".utf8)) == 400)
        #expect(status(Data("POST /mcp HTTP/1.1\r\nHost: localhost\n\n".utf8)) == 400)
        // Rejected as soon as the bare LF arrives, before the header section ends.
        #expect(status(Data("POST /mcp HTTP/1.1\n".utf8)) == 400)
    }

    @Test func obsFold400() {
        #expect(status(Self.raw(Self.post + "\r\nX-A: one\r\n two\r\nContent-Length: 0")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nX-A: one\r\n\ttwo\r\nContent-Length: 0")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nNo colon here\r\nContent-Length: 0")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nBad Key: x\r\nContent-Length: 0")) == 400)
        #expect(status(Self.raw(Self.post + "\r\n: empty key\r\nContent-Length: 0")) == 400)
    }

    @Test func controlBytesInHeaderValue400() {
        for value in ["127.0.0.1\r:41000", "a\u{0}b", "a\u{1B}b", "a\u{7F}"] {
            #expect(status(Self.raw(Self.post + "\r\nContent-Length: 0\r\nX-A: \(value)")) == 400, "\(value.debugDescription)")
        }
        // HT inside a value and bytes above 0x7F (obs-text) are allowed.
        #expect((try? request(Self.raw(Self.post + "\r\nContent-Length: 0\r\nX-A: a\tb é"))) != nil)
    }

    @Test func duplicateContentLength400() {
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: 2\r\ncontent-length: 2", body: "{}")) == 400)
    }

    @Test func duplicateHostOrOriginOrAuthorization400() {
        for name in ["Host", "Origin", "Authorization", "Content-Type", "MCP-Protocol-Version"] {
            let head = Self.post + "\r\nContent-Length: 2\r\n\(name): a\r\n\(name.lowercased()): b"
            #expect(status(Self.raw(head, body: "{}")) == 400, "\(name)")
        }
    }

    @Test func hugeContentLengthNoTrap() {
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: 99999999999999999999")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: 12345678")) == 400)
    }

    @Test func negativeContentLength400() {
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: -1")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: +2", body: "{}")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: 2, 2", body: "{}")) == 400)
        #expect(status(Self.raw(Self.post + "\r\nContent-Length: ", body: "{}")) == 400)
    }
}
