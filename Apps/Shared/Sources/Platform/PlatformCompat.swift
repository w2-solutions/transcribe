import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import CoreAudio
#endif

/// iOS-only SwiftUI modifiers and values, wrapped so the shared views compile for both apps.
/// On iOS every helper expands to exactly the modifier it replaces; the macOS branches arrive with the Mac app.
extension View {
    /// iOS: `.navigationBarTitleDisplayMode(.inline)`.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// iOS: `.navigationBarTitleDisplayMode(.large)`.
    func largeNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    /// iOS: `.textInputAutocapitalization(_:)`. (Not named `autocapitalization`: that clashes with UIKit's deprecated modifier.)
    func inputCapitalization(_ kind: CompatCapitalization) -> some View {
        #if os(iOS)
        textInputAutocapitalization(kind.uiValue)
        #else
        self
        #endif
    }

    /// iOS: `.fullScreenCover(isPresented:content:)`. The Mac app shows recording in its own window instead.
    func presentRecording(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        self
        #endif
    }

    /// iOS: unchanged (the sheet's root carries its identifier). On the Mac a sheet whose root is a `NavigationStack`
    /// loses the root's identifier, so the content inside the stack carries it as well.
    func macSheetIdentifier(_ id: String) -> some View {
        #if os(iOS)
        self
        #else
        accessibilityElement(children: .contain).accessibilityIdentifier(id)
        #endif
    }

    /// iOS: unchanged (sheets fill the screen). Sizes a sheet on the Mac.
    func sheetSizing(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(iOS)
        self
        #else
        frame(minWidth: minWidth, minHeight: minHeight)
        #endif
    }
}

enum CompatCapitalization {
    case never, words, sentences

    #if os(iOS)
    var uiValue: TextInputAutocapitalization {
        switch self {
        case .never: .never
        case .words: .words
        case .sentences: .sentences
        }
    }
    #endif
}

extension ToolbarItemPlacement {
    /// iOS: `.topBarTrailing`.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    /// iOS: `.topBarLeading`.
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .cancellationAction
        #endif
    }
}

extension SearchFieldPlacement {
    /// iOS: `.navigationBarDrawer(displayMode: .always)`.
    static var librarySearch: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .toolbar
        #endif
    }
}

enum Platform {
    /// Where the microphone permission is changed: the app's page in Settings on iOS.
    static var micSettingsURL: URL {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        #endif
    }

    /// Mac only: where "Screen & System Audio Recording" is allowed (the Mac audio silent note's button). Not yet
    /// checked by hand on macOS 27: if it opens the wrong pane, Privacy & Security is one level up.
    static var macAudioSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }

    /// DEBUG test runs only (`TRANSCRIBE_OUTPUT_ROUTE`, set by `Composition` with the fake engine or UI tests): the
    /// output route to report instead of the Mac's ("builtInSpeaker", "headphones", …; `CaptureDetail.OutputRoute`).
    static var outputRouteOverride: String?

    /// The Mac's sound plays through its built-in speakers now, so a microphone recording at the same time hears the
    /// far side of a call too (the headphones hint). False on the iPhone, and whenever the route cannot be read.
    static func outputIsBuiltInSpeaker() -> Bool {
        if let outputRouteOverride { return outputRouteOverride == "builtInSpeaker" }
        #if os(macOS)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        // The built-in output: its speakers ('ispk') or the headphone jack ('hdpn'). No data source reads as speakers.
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDataSource
        address.mScope = kAudioDevicePropertyScopeOutput
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else { return true }
        return source != 0x6864_706E   // 'hdpn'
        #else
        return false
        #endif
    }
}
