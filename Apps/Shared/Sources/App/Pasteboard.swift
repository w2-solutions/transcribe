import UIKit
import UniformTypeIdentifiers

enum Pasteboard {
    static func copy(_ text: String) { UIPasteboard.general.string = text }

    /// This device only (no Universal Clipboard), cleared after 10 minutes. For diagnostics that must not leave the iPhone.
    static func copyPrivate(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
    }
}
