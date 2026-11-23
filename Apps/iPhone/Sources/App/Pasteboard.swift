import UIKit

enum Pasteboard {
    static func copy(_ text: String) { UIPasteboard.general.string = text }
}
