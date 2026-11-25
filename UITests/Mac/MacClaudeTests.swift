import AppKit
import CryptoKit
import XCTest

/// Settings → Claude (Mac only): the switch, the status, the Claude Code command on the clipboard (no key, no port),
/// a pairing request shown in Settings and as an alert on the main window, Allow, Remove and Don't Allow, and the
/// privacy footer following the switch. The app runs in a temporary root on a throwaway port
/// (`TRANSCRIBE_MCP_TEST_PORT`), so nothing touches the real ports or `ClaudeAccess.json`; the test itself sends the
/// pairing requests a Claude app's helper would. Never clicks Add to Claude Desktop… (it opens a save panel and the
/// real Claude).
final class MacClaudeTests: FlowTestCase {
    @MainActor func testTurnOnPairAllowRemoveDenyAndOff() async throws {
        let port = UInt16.random(in: 39_000...39_999)
        let app = UITestApp.launch(seed: "library", extraEnvironment: ["TRANSCRIBE_MCP_TEST_PORT": String(port)])
        app.waitFor(AX.Mac.main, timeout: 20)
        Wait.label(app.waitFor(AX.Mac.sidebarFooter), contains: "Nothing is uploaded")
        app.shortcut(",")
        app.waitFor(AX.Settings.screen)

        let master = app.scrollTo(AX.Claude.master)
        XCTAssertFalse(master.isOn, "Claude access is off until the user turns it on")
        Wait.label(app.scrollTo(AX.Claude.explanation), contains: "sent to Anthropic")
        XCTAssertFalse(app.element(AX.Claude.status).exists, "No status while off")
        app.scrollTo(AX.Claude.master).flipSwitch()
        Wait.switchState(master, on: true)
        Wait.label(app.waitFor(AX.Claude.status), contains: "On", timeout: 15)
        Wait.label(app.waitFor(AX.Claude.allowNote), contains: "allowed once")
        app.waitFor(AX.Claude.noAllowedApps)

        // Add to Claude Code: one line, no key, no port, no environment. (The command is the same every time, so a
        // marker goes on the clipboard first.)
        let before = "MacClaudeTests \(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(before, forType: .string)
        app.scrollTo(AX.Claude.addCode).click()
        let command = clipboard(after: before)
        XCTAssertTrue(command.hasPrefix("claude mcp remove --scope user transcribe >/dev/null 2>&1; "), command)
        XCTAssertTrue(command.contains("claude mcp add --scope user --transport stdio transcribe -- '"), command)
        XCTAssertTrue(command.hasSuffix("Contents/Helpers/transcribe-mcp'"), command)
        XCTAssertFalse(command.contains("--env") || command.contains("TRANSCRIBE_MCP"), command)
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "Claude can read")

        // A Claude app asks: Settings shows the request with its code, and the main window shows the alert.
        let client = PairingClient(name: "UI Test Claude")
        let pending = try await client.pair(port: port)
        XCTAssertEqual(pending.status, "pending")
        let row = app.waitFor(AX.Claude.request(client.id))
        Wait.label(row, contains: "UI Test Claude")
        Wait.label(row, contains: "Code \(try XCTUnwrap(pending.code))")
        let alertTitle = app.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", Self.title("UI Test Claude"), Self.title("UI Test Claude")))
            .firstMatch
        XCTAssertTrue(alertTitle.waitForExistence(timeout: 5), "No Allow alert on the main window")

        // Allow, in the alert (it brings the main window in front of Settings): the alert and the request in
        // Settings go, and the app is listed.
        alertButton(app, "Allow", notID: AX.Claude.requestAllow(client.id)).click()
        XCTAssertTrue(alertTitle.waitForNonExistence(timeout: 5), "The alert stayed after Allow")
        app.waitForGone(AX.Claude.request(client.id))
        app.shortcut(",")
        Wait.label(app.waitFor(AX.Claude.allowedApp(client.id)), contains: "UI Test Claude")
        // Transcribe holds that client id now: it cannot start another pairing under it.
        let allowed = try await client.pair(port: port)
        XCTAssertEqual(allowed.status, "conflict")

        // Remove (confirmed), in Settings: gone from the list, and Transcribe no longer knows it.
        app.scrollTo(AX.Claude.removeApp(client.id)).click()
        app.button(AX.Claude.removeConfirm, title: "Remove").click()
        app.waitForGone(AX.Claude.allowedApp(client.id))
        app.waitFor(AX.Claude.noAllowedApps)
        let again = try await client.pair(port: port)
        XCTAssertEqual(again.status, "pending", "A removed app asks again")
        app.waitFor(AX.Claude.request(client.id))
        XCTAssertTrue(alertTitle.waitForExistence(timeout: 5), "No alert for the new request")

        // Don't Allow, in the alert: the request goes, and asking again is refused for now without a new prompt.
        alertButton(app, "Don't Allow", notID: AX.Claude.requestDeny(client.id)).click()
        XCTAssertTrue(alertTitle.waitForNonExistence(timeout: 5), "The alert stayed after Don't Allow")
        app.waitForGone(AX.Claude.request(client.id))
        let denied = try await client.pair(port: port)
        XCTAssertEqual(denied.status, "denied")
        XCTAssertFalse(alertTitle.waitForExistence(timeout: 2), "Asking again after Don't Allow shows nothing new")
        XCTAssertFalse(app.element(AX.Claude.request(client.id)).exists)

        // Off: no status, the removal help, and the footer is back.
        app.shortcut(",")
        app.scrollTo(AX.Claude.master).flipSwitch()
        Wait.switchState(master, on: false)
        app.waitForGone(AX.Claude.status)
        app.waitFor(AX.Claude.removeHelp)
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "Nothing is uploaded")
    }

    static func title(_ name: String) -> String { "Allow “\(name)” to read your transcripts?" }

    /// The alert's button with this title: by the alert's identifier if macOS carries it, else the button with this
    /// title that is not the Settings row's (which has the same title).
    @MainActor private func alertButton(_ app: XCUIApplication, _ title: String, notID settingsID: String,
                                        file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let id = title == "Allow" ? AX.Claude.alertAllow : AX.Claude.alertDeny
        let byID = app.element(id)
        if byID.waitForExistence(timeout: 1) { return byID }
        let byTitle = app.windows.buttons.matching(NSPredicate(format: "(label == %@ OR title == %@) AND identifier != %@",
                                                               title, title, settingsID)).firstMatch
        XCTAssertTrue(byTitle.waitForExistence(timeout: 5), "No “\(title)” button in the alert", file: file, line: line)
        return byTitle
    }

    /// The command on the general pasteboard once one other than `previous` is there (the click copies asynchronously).
    @MainActor private func clipboard(after previous: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                return text.contains("claude mcp add") && text != previous
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 5), .completed, "No new command on the clipboard", file: file, line: line)
        return NSPasteboard.general.string(forType: .string) ?? ""
    }
}

/// What a Claude app's helper sends to `POST /pair`, commit then reveal (written out here, as the helper's code is not
/// in the UI test target): a random client id, a Curve25519 public key, and a commitment to a fresh nonce, then the
/// nonce.
struct PairingClient {
    let id = Self.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
    let key = Curve25519.KeyAgreement.PrivateKey()
    let name: String

    var publicKey: String { Self.base64URL(key.publicKey.rawRepresentation) }

    /// One pairing request with a fresh nonce: "pending", "allowed" or "denied" after the reveal, "denied" for a commit
    /// from a client held as denied, or "conflict" (409) for an id Transcribe already holds; with the code Transcribe
    /// shows ("482 913") when the reveal went through.
    func pair(port: UInt16) async throws -> (status: String, code: String?) {
        let nonce = Self.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let commitment = Self.digest("TRANSCRIBE-MCP-PAIR-2 commit\n\(id)\n\(publicKey)\n\(nonce)")
        let (commitStatus, commit) = try await post(port: port, [
            "v": 2, "client_id": id, "client_name": name, "client_key": publicKey, "commit": commitment,
        ])
        if commitStatus == 409 { return ("conflict", nil) }
        XCTAssertEqual(commitStatus, 200)
        guard commit["status"] as? String == "reveal", let appKey = commit["app_key"] as? String,
              let appNonce = commit["app_nonce"] as? String else { return (commit["status"] as? String ?? "", nil) }
        let (revealStatus, reveal) = try await post(port: port, ["v": 2, "client_id": id, "client_key": publicKey, "reveal": nonce])
        XCTAssertEqual(revealStatus, 200)
        let transcript = Self.digest("TRANSCRIBE-MCP-PAIR-2 transcript\n\(id)\n\(publicKey)\n\(appKey)\n\(appNonce)\n\(nonce)")
        return (reveal["status"] as? String ?? "", Self.code(transcript))
    }

    private func post(port: UInt16, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    /// The code both sides show, computed as the helper computes it.
    static func code(_ transcript: String) -> String {
        let digest = SHA256.hash(data: Data("TRANSCRIBE-MCP-PAIR-2 code\n\(transcript)".utf8))
        let n = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let digits = String(format: "%06llu", n)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    static func digest(_ text: String) -> String { base64URL(Data(SHA256.hash(data: Data(text.utf8)))) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
