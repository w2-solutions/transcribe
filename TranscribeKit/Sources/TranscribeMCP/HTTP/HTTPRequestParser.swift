import Foundation

/// The result of parsing what a connection has sent so far.
enum HTTPParse: Equatable {
    /// The header section is not complete yet.
    case needMore
    /// The headers are complete and valid, the body is not (lets the server clear its 2 s header deadline). `total` is
    /// the byte count the whole request needs (header section plus Content-Length), so the server can count body bytes
    /// without parsing the header section again.
    case headersComplete(total: Int)
    case request(HTTPRequest)
    /// Malformed: answer with this (400, 411, 413 or 431, empty body) and close.
    case reject(HTTPResponse)

    static func == (a: HTTPParse, b: HTTPParse) -> Bool {
        switch (a, b) {
        case (.needMore, .needMore): true
        case (.headersComplete(let x), .headersComplete(let y)): x == y
        case (.reject(let x), .reject(let y)): x == y
        case (.request(let x), .request(let y)):
            x.method == y.method && x.path == y.path && x.headers == y.headers && x.body == y.body
        default: false
        }
    }
}

/// A minimal, strict HTTP/1.1 request parser for one request per connection (§3.1). Anything it does not expect is
/// rejected rather than guessed at. Bytes past the header section plus Content-Length are ignored: a second request
/// on the same connection is never read.
enum HTTPRequestParser {
    /// Headers that may appear at most once.
    static let singletons: Set<String> = ["content-length", "host", "authorization", "origin", "content-type",
                                          "mcp-protocol-version", "transfer-encoding"]

    static func parse(_ buffer: Data, maxHeader: Int = 16_384, maxBody: Int = 1_048_576) -> HTTPParse {
        let bytes = [UInt8](buffer.prefix(maxHeader))
        // A bare LF anywhere in the header section is rejected at once, before the section is complete.
        var end: Int?
        for i in bytes.indices where bytes[i] == lf {
            guard i > 0, bytes[i - 1] == cr else { return reject(400) }
            if i >= 3, bytes[i - 2] == lf, bytes[i - 3] == cr { end = i + 1; break }
        }
        guard let end else { return buffer.count >= maxHeader ? reject(431) : .needMore }

        // Lines of the header section, without their CRLF; the last two are the empty line's.
        var lines = split(bytes[0..<(end - 2)])
        guard !lines.isEmpty else { return reject(400) }
        guard let (method, path) = requestLine(lines.removeFirst()) else { return reject(400) }

        // Repeated non-singleton headers are joined once at the end (no quadratic string building).
        var fields: [String: [String]] = [:]
        for line in lines {
            guard let first = line.first, first != sp, first != ht else { return reject(400) }   // obs-fold
            guard let colon = line.firstIndex(of: colonByte), colon > line.startIndex,
                  line[line.startIndex..<colon].allSatisfy(isToken) else { return reject(400) }
            let key = String(decoding: line[line.startIndex..<colon], as: UTF8.self).lowercased()
            let raw = line[(colon + 1)...].drop { $0 == sp || $0 == ht }
            // Field values are visible bytes, SP and HT: a bare CR, NUL or other control byte is rejected.
            guard raw.allSatisfy({ $0 == ht || ($0 >= sp && $0 != 0x7F) }) else { return reject(400) }
            let value = String(decoding: raw.reversed().drop { $0 == sp || $0 == ht }.reversed(), as: UTF8.self)
            if fields[key] != nil, singletons.contains(key) { return reject(400) }
            fields[key, default: []].append(value)
        }
        let headers = fields.mapValues { $0.joined(separator: ", ") }

        if headers["transfer-encoding"] != nil { return reject(411) }
        var length = 0
        if let cl = headers["content-length"] {
            guard (1...7).contains(cl.utf8.count), cl.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(cl)
            else { return reject(400) }
            guard n <= maxBody else { return reject(413) }
            length = n
        } else if method == "POST" {
            return reject(411)
        }

        guard buffer.count - end >= length else { return .headersComplete(total: end + length) }
        let start = buffer.startIndex + end
        return .request(HTTPRequest(method: method, path: path, headers: headers,
                                    body: Data(buffer[start..<(start + length)])))
    }

    /// `METHOD SP target SP HTTP/1.1`, METHOD `[A-Z]{1,16}`, a target of visible ASCII. Returns the path without query.
    private static func requestLine(_ line: ArraySlice<UInt8>) -> (String, String)? {
        let parts = line.split(separator: sp, omittingEmptySubsequences: false)
        guard parts.count == 3, (1...16).contains(parts[0].count), parts[0].allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
              String(decoding: parts[2], as: UTF8.self) == "HTTP/1.1" else { return nil }
        let target = String(decoding: parts[1], as: UTF8.self)
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        return (String(decoding: parts[0], as: UTF8.self), path ?? target)
    }

    /// Splits on CRLF (every LF here is known to follow a CR).
    private static func split(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        bytes.split(separator: lf, omittingEmptySubsequences: false).dropLast().map { $0.dropLast() }
    }

    private static func isToken(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: "!#$%&'*+-.^_`|~".utf8.contains(b)
        }
    }

    private static func reject(_ status: Int) -> HTTPParse { .reject(HTTPResponse(status: status)) }

    private static let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A, sp: UInt8 = 0x20, ht: UInt8 = 0x09, colonByte: UInt8 = 0x3A
}
