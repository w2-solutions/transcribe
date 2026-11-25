// Ed25519 signing for Sparkle updates, with Apple's CryptoKit only: the release key never reaches third-party code.
//
//   xcrun swift scripts/ed25519.swift public-key                          < seed   prints the base64 public key
//   xcrun swift scripts/ed25519.swift sign <file>                         < seed   prints the base64 signature of <file>
//   xcrun swift scripts/ed25519.swift verify <public-key> <signature> <file>       exit 0 valid, 1 invalid
//   xcrun swift scripts/ed25519.swift sign-feed <in.xml> <out.xml>        < seed   writes a signed appcast
//   xcrun swift scripts/ed25519.swift verify-feed <public-key> <file>              exit 0 valid, 1 invalid or unsigned
//
// The seed (the private key, as Sparkle's generate_keys stores and exports it: base64 of 32 bytes) is read from
// standard input only, never from an argument, so it is never on a command line. It is never printed, and a bad seed
// is reported without echoing it. Keys and signatures on the command line are public.
//
// The signed-feed format is Sparkle's own (common_cli/Signing.swift, signAppcast): the appcast content, then
// "<!-- sparkle-signatures:\nedSignature: <base64>\nlength: <bytes>\n-->\n". verify-feed reads it exactly as
// Sparkle's SPUExtractAppcastContent does: the signed content is every byte before the LAST signature prefix, and
// the block ends at the first "-->" after it. It also requires "length" to equal the content's byte count.
//
// Exit codes: 0 done or valid; 1 a signature does not verify (or a feed is unsigned); 2 usage, unreadable input or
// a malformed key or signature.
import CryptoKit
import Foundation

let feedPrefix = Data("<!-- sparkle-signatures:\n".utf8)
let feedSuffix = Data("-->".utf8)

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("ed25519: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    fail("""
        usage: ed25519.swift public-key | sign <file> | verify <public-key> <signature> <file> |
               sign-feed <in.xml> <out.xml> | verify-feed <public-key> <file>   (the seed comes on standard input)
        """)
}

func readFile(_ path: String) -> Data {
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    } catch {
        fail("cannot read \(path)")
    }
}

/// The private key from standard input: trimmed, base64, exactly 32 bytes. Never echoed.
func readSeed() -> Curve25519.Signing.PrivateKey {
    let input = (try? FileHandle.standardInput.readToEnd()) ?? nil
    guard let input, let text = String(data: input, encoding: .utf8) else { fail("no seed on standard input") }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: trimmed), seed.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    else { fail("the seed on standard input is not base64 of 32 bytes") }
    return key
}

func publicKey(_ base64: String) -> Curve25519.Signing.PublicKey {
    guard let raw = Data(base64Encoded: base64), raw.count == 32,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("the public key is not base64 of 32 bytes") }
    return key
}

func signature(_ base64: String) -> Data {
    guard let raw = Data(base64Encoded: base64), raw.count == 64 else { fail("the signature is not base64 of 64 bytes") }
    return raw
}

func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) -> String {
    guard let sig = try? key.signature(for: data) else { fail("signing failed", 1) }
    return sig.base64EncodedString()
}

/// Splits a signed feed as SPUExtractAppcastContent does. nil when there is no complete signature block.
func extractFeed(_ data: Data) -> (content: Data, signature: String?, length: UInt64)? {
    guard let prefix = data.range(of: feedPrefix, options: .backwards),
          let suffix = data.range(of: feedSuffix, in: prefix.upperBound..<data.endIndex)
    else { return nil }
    guard let block = String(data: data[prefix.upperBound..<suffix.lowerBound], encoding: .utf8) else { return nil }
    var sig: String?
    var length: UInt64 = 0
    block.enumerateLines { line, _ in
        if line.hasPrefix("edSignature:") {
            sig = line.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if line.hasPrefix("length:") {
            length = UInt64(line.dropFirst("length:".count).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
    }
    return (Data(data[data.startIndex..<prefix.lowerBound]), sig, length)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch (command, args.count) {
case ("public-key", 1):
    print(readSeed().publicKey.rawRepresentation.base64EncodedString())

case ("sign", 2):
    let key = readSeed()
    print(sign(readFile(args[1]), with: key))

case ("verify", 4):
    let key = publicKey(args[1])
    let sig = signature(args[2])
    guard key.isValidSignature(sig, for: readFile(args[3])) else { fail("the signature does not verify: \(args[3])", 1) }

case ("sign-feed", 3):
    let key = readSeed()
    let content = readFile(args[1])
    guard content.range(of: feedPrefix) == nil else { fail("\(args[1]) already has a signature block") }
    var signed = content
    signed.append(Data("<!-- sparkle-signatures:\nedSignature: \(sign(content, with: key))\nlength: \(content.count)\n-->\n".utf8))
    do {
        try signed.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    } catch {
        fail("cannot write \(args[2])")
    }

case ("verify-feed", 3):
    let key = publicKey(args[1])
    guard let feed = extractFeed(readFile(args[2])) else { fail("\(args[2]) has no signature block", 1) }
    guard let sigText = feed.signature, let sig = Data(base64Encoded: sigText), sig.count == 64 else {
        fail("\(args[2]) has no valid edSignature", 1)
    }
    guard feed.length == UInt64(feed.content.count) else {
        fail("\(args[2]): length \(feed.length) in the signature block, but the content is \(feed.content.count) bytes", 1)
    }
    guard key.isValidSignature(sig, for: feed.content) else { fail("the feed signature does not verify: \(args[2])", 1) }

default:
    usage()
}
