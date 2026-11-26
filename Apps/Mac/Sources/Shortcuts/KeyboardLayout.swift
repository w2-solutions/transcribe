import Carbon
import TranscribeKit

/// The current keyboard layout (the only file that uses Text Input Sources and `UCKeyTranslate`). Main actor only:
/// the TIS calls must run on the main thread.
///
/// Key codes are physical positions, so "the key that types v" differs between layouts (on Dvorak it is the key
/// QWERTY calls "."). Pasting must press the key the layout turns into ⌘V, and the shortcut recorder shows the label
/// the user sees on that key.
@MainActor enum KeyboardLayout {
    /// The key code that types "v" with ⌘ held in the current layout. Translating with ⌘ held covers layouts that
    /// switch to QWERTY under ⌘ ("Dvorak - QWERTY ⌘"). nil when the layout cannot be read (the caller uses
    /// `KeyCodes.v`).
    static func keyCodeTypingV() -> UInt16? {
        guard let layout = currentLayout() else { return nil }
        let command = UInt32((cmdKey >> 8) & 0xFF)
        for code in UInt16(0)..<128 where !KeyCodes.modifierKeys.contains(code) {
            if translate(code, modifierState: command, layout: layout)?.lowercased() == "v" { return code }
        }
        return nil
    }

    /// What the key prints with no modifiers in the current layout, upper-cased ("Z", "Ä", "/"); nil for keys that
    /// print nothing or when the layout cannot be read.
    static func label(for keyCode: UInt16) -> String? {
        guard let layout = currentLayout(),
              let text = translate(keyCode, modifierState: 0, layout: layout)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !text.isEmpty else { return nil }
        return text.uppercased()
    }

    /// The layout data of the current keyboard layout, or of the ASCII-capable one an input method types with. Each
    /// source is copied only when needed and released at once (`takeRetainedValue`): both copy functions return +1.
    private static func currentLayout() -> Data? {
        if let data = layoutData(TISCopyCurrentKeyboardLayoutInputSource()) { return data }
        return layoutData(TISCopyCurrentASCIICapableKeyboardLayoutInputSource())
    }

    private static func layoutData(_ copied: Unmanaged<TISInputSource>?) -> Data? {
        guard let source = copied?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.isEmpty ? nil : data
    }

    private static func translate(_ keyCode: UInt16, modifierState: UInt32, layout: Data) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
                                  UInt16(kUCKeyActionDisplay), modifierState, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
