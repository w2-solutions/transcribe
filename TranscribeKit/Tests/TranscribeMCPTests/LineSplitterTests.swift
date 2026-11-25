import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: stdio line splitter")
struct LineSplitterTests {
    func lines(_ bytes: Data, maxLine: Int = 4_194_304) -> [LineSplitter.Line] {
        var splitter = LineSplitter(maxLine: maxLine)
        var out = bytes.compactMap { splitter.feed($0) }
        if let last = splitter.finish() { out.append(last) }
        return out
    }

    @Test func splitsOnLFOnly() {
        #expect(lines(Data("a\nbb\n\nccc".utf8)) == [.line(Data("a".utf8)), .line(Data("bb".utf8)), .line(Data()),
                                                     .line(Data("ccc".utf8))])
        #expect(lines(Data("one\n".utf8)) == [.line(Data("one".utf8))])
        #expect(lines(Data()).isEmpty)
    }

    @Test func unicodeLineSeparatorsInsideStringsStayOneMessage() throws {
        let text = "a\u{2028}b\u{2029}c\u{0085}d\re"
        // The separators raw in the bytes, as a client may send them (U+2028/9 and U+0085 are legal raw in JSON).
        let raw = Data(#"{"jsonrpc":"2.0","method":"x","params":{"t":""#.utf8) + Data(text.utf8) + Data(#""}}"#.utf8)
        let message = JSONValue.object(["jsonrpc": "2.0", "method": "y", "params": ["t": .string(text)]]).encoded()
        let split = lines(raw + Data([0x0A]) + message + Data([0x0A]))
        #expect(split == [.line(raw), .line(message)])
        #expect(message.json["params"]?["t"]?.string == text)
    }

    @Test func stripsTrailingCR() {
        #expect(lines(Data("a\r\nb\r\r\nc\r".utf8)) == [.line(Data("a".utf8)), .line(Data("b\r".utf8)),
                                                         .line(Data("c".utf8))])
    }

    @Test func tooLongThenRecovers() {
        let long = Data(String(repeating: "x", count: 20).utf8)
        #expect(lines(long + Data("\nok\n".utf8), maxLine: 10) == [.tooLong, .line(Data("ok".utf8))])
        #expect(lines(Data(String(repeating: "x", count: 10).utf8) + Data("\n".utf8), maxLine: 10)
                    == [.line(Data(String(repeating: "x", count: 10).utf8))])
        #expect(lines(long, maxLine: 10) == [.tooLong])
    }
}
