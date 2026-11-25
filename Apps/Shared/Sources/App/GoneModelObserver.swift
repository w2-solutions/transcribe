import Foundation
import SwiftData
import SwiftUI
import TranscribeKit

/// Recordings and voices deleted while on screen (§8.4: sync applies another device's delete, or a delete elsewhere
/// on this device). Their screens and name sheets are dropped (`Router.dropGone`), and the player stops when the
/// audio it holds was deleted with its recording. The Mac lists clear their own selection.
struct GoneModelObserver: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Query private var recordings: [Recording]
    @Query private var profiles: [VoiceProfile]

    func body(content: Content) -> some View {
        content
            .onChange(of: recordings.map(\.id)) { old, new in
                let gone = GoneModels.removed(before: old, after: new)
                guard !gone.isEmpty else { return }
                router.dropGone(recordings: gone, profiles: [])
                if let url = env.player.loadedURL, !FileManager.default.fileExists(atPath: url.path) { env.player.stop() }
            }
            .onChange(of: profiles.map(\.id)) { old, new in
                router.dropGone(recordings: [], profiles: GoneModels.removed(before: old, after: new))
            }
    }
}
