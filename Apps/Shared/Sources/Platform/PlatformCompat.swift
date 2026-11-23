import SwiftUI
#if os(iOS)
import UIKit
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
}
