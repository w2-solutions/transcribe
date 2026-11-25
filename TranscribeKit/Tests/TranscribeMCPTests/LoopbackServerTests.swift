import Foundation
import Synchronization
import Testing
@testable import TranscribeMCP

/// A blocking TCP client for poking the server byte by byte.
final class RawClient {
    let fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func send(_ s: String) { _ = Data(s.utf8).withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }

    /// Reads until the server closes or `timeout` passes. `closed` is true when the server ended the connection.
    func readAll(timeout: TimeInterval) -> (data: Data, closed: Bool) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { data.append(contentsOf: buffer[0..<n]); continue }
            if n == 0 { return (data, true) }
            if errno == EAGAIN || errno == EWOULDBLOCK { return (data, false) }
            return (data, true)   // ECONNRESET and the like: closed
        }
        return (data, false)
    }
}

extension LoopbackHTTPServer {
    /// A server that answers every request with 200 and the request body.
    static func echo(port: UInt16 = 0, headerDeadline: Duration = .seconds(2), requestDeadline: Duration = .seconds(10),
                     maxConnections: Int = 16) -> LoopbackHTTPServer {
        LoopbackHTTPServer(port: port, headerDeadline: headerDeadline, requestDeadline: requestDeadline,
                           maxConnections: maxConnections) { r in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: r.body)
        }
    }
}

final class ParseCounter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

func post(_ body: String, length: Int? = nil) -> String {
    "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(length ?? body.utf8.count)\r\n\r\n" + body
}

@Suite("MCP: loopback server", .serialized)
struct LoopbackServerTests {
    @Test func bindsLoopbackAndReturnsPort() async throws {
        let server = LoopbackHTTPServer.echo()
        defer { server.stop() }
        let port = try await server.start()
        #expect(port > 0)
        let client = try #require(RawClient(port: port))
        client.send(post("{}"))
        let (data, closed) = client.readAll(timeout: 2)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("\r\n\r\n{}") && closed)
    }

    @Test func servesPOSTOverURLSession() async throws {
        let server = LoopbackHTTPServer.echo()
        defer { server.stop() }
        let port = try await server.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hello":"world"}"#.utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200 && data == request.httpBody)
        #expect(http.value(forHTTPHeaderField: "Connection") == "close")
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        // A malformed request is answered by the parser and closed.
        let client = try #require(RawClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(String(decoding: client.readAll(timeout: 2).data, as: UTF8.self).hasPrefix("HTTP/1.1 411 "))
    }

    @Test func secondBindOnSamePortIsPortInUse() async throws {
        let first = LoopbackHTTPServer.echo()
        defer { first.stop() }
        let port = try await first.start()
        let second = LoopbackHTTPServer.echo(port: port)
        defer { second.stop() }
        await #expect(throws: LoopbackError.portInUse(port)) { try await second.start() }
    }

    @Test func stopFreesPort() async throws {
        let first = LoopbackHTTPServer.echo()
        let port = try await first.start()
        // Serve a request first: the server closes after replying, so its side of that connection is in TIME_WAIT.
        let client = try #require(RawClient(port: port))
        client.send(post("{}"))
        #expect(client.readAll(timeout: 2).closed)
        first.stop()
        try await Task.sleep(for: .milliseconds(100))
        let second = LoopbackHTTPServer.echo(port: port)
        defer { second.stop() }
        #expect(try await second.start() == port)
        let again = try #require(RawClient(port: port))
        again.send(post("{}"))
        #expect(String(decoding: again.readAll(timeout: 2).data, as: UTF8.self).hasPrefix("HTTP/1.1 200 "))
    }

    @Test func stopClosesOpenConnections() async throws {
        let server = LoopbackHTTPServer.echo()
        let port = try await server.start()
        let client = try #require(RawClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Le")
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        server.stop()
        let (data, closed) = client.readAll(timeout: 2)
        #expect(closed && data.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
        // And nothing listens any more.
        #expect(RawClient(port: port) == nil)
    }

    @Test func trickledHeadersClosedAfterHeaderDeadline() async throws {
        let server = LoopbackHTTPServer.echo(headerDeadline: .milliseconds(300))
        defer { server.stop() }
        let port = try await server.start()
        let slow = try #require(RawClient(port: port))
        let started = Date()
        for piece in ["POST ", "/mcp ", "HTTP/1.1\r\n", "Host: "] {
            slow.send(piece)
            try await Task.sleep(for: .milliseconds(50))
        }
        let (data, closed) = slow.readAll(timeout: 2)
        #expect(closed && data.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1.5)
        // Headers finished in time: the header deadline no longer applies.
        let ok = try #require(RawClient(port: port))
        ok.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{")
        try await Task.sleep(for: .milliseconds(500))
        ok.send("}")
        #expect(String(decoding: ok.readAll(timeout: 2).data, as: UTF8.self).hasPrefix("HTTP/1.1 200 "))
    }

    @Test func requestDeadlineIsAbsolute() async throws {
        let server = LoopbackHTTPServer.echo(headerDeadline: .seconds(5), requestDeadline: .milliseconds(500))
        defer { server.stop() }
        let port = try await server.start()
        let client = try #require(RawClient(port: port))
        let started = Date()
        client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\n")
        // Keep sending a byte every 100 ms: activity does not extend the deadline.
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(100))
            client.send("x")
        }
        let (data, closed) = client.readAll(timeout: 2)
        #expect(closed && data.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func bodyChunksDoNotReparseHeaders() async throws {
        // A body sent in many small pieces: the header section is parsed when it completes and once more when the
        // whole request is in, not on every piece (an unauthenticated sender could otherwise burn CPU).
        let calls = ParseCounter()
        let server = LoopbackHTTPServer(port: 0, headerDeadline: .seconds(2), requestDeadline: .seconds(10),
                                        maxConnections: 16, onFailure: { _ in },
                                        parse: { data in calls.bump(); return HTTPRequestParser.parse(data) },
                                        handler: { r in HTTPResponse(status: 200, body: r.body) })
        defer { server.stop() }
        let port = try await server.start()
        let client = try #require(RawClient(port: port))
        let body = String(repeating: "x", count: 20)
        client.send(post("", length: body.utf8.count))
        try await Task.sleep(for: .milliseconds(100))
        for c in body {
            client.send(String(c))
            try await Task.sleep(for: .milliseconds(15))
        }
        let reply = String(decoding: client.readAll(timeout: 2).data, as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 200 ") && reply.hasSuffix(body))
        #expect(calls.value <= 3, "parsed \(calls.value) times")
    }

    @Test func capEvictsUnfinishedConnection() async throws {
        let server = LoopbackHTTPServer.echo(maxConnections: 2)
        defer { server.stop() }
        let port = try await server.start()
        let unfinished = try #require(RawClient(port: port))
        unfinished.send("POST /mcp HTTP/1.1\r\nHo")
        try await Task.sleep(for: .milliseconds(100))
        let headersDone = try #require(RawClient(port: port))
        headersDone.send(post("", length: 2) + "{")
        try await Task.sleep(for: .milliseconds(100))

        // At the cap: the connection still sending headers makes room.
        let third = try #require(RawClient(port: port))
        third.send(post("", length: 2) + "{")
        #expect(unfinished.readAll(timeout: 1).closed)

        // Now both live connections have finished their headers, so a new one is dropped.
        let fourth = try #require(RawClient(port: port))
        fourth.send(post("{}"))
        #expect(fourth.readAll(timeout: 1) == (Data(), true))

        // The two that made it are still served.
        headersDone.send("}")
        third.send("}")
        #expect(String(decoding: headersDone.readAll(timeout: 2).data, as: UTF8.self).hasPrefix("HTTP/1.1 200 "))
        #expect(String(decoding: third.readAll(timeout: 2).data, as: UTF8.self).hasPrefix("HTTP/1.1 200 "))
    }
}
