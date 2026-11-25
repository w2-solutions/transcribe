import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Diagnostics and Claude setup text, which must not leave the device. iOS: this device only (no Universal
    /// Clipboard), cleared after 10 minutes. Mac: `.currentHostOnly` keeps it out of Universal Clipboard, and the
    /// transient and concealed markers tell clipboard managers to skip it.
    static func copyPrivate(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        #else
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.writeObjects([item])
        #endif
    }
}
