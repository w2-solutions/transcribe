import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// A question sync cannot answer alone (§8.4 flows 1 and 7): another Apple Account is signed in
/// (`AccountChangeSheet`), or the launch scan found many items deleted here (`MassDeleteSheet`).
enum SyncQuestion: String, Identifiable {
    case accountChanged, massDelete

    var id: String { rawValue }

    init?(_ status: SyncStatus) {
        switch status {
        case .paused(.accountChanged): self = .accountChanged
        case .paused(.massDelete): self = .massDelete
        default: return nil
        }
    }

    /// The Settings row that reopens the question.
    var reviewTitle: String {
        switch self {
        case .accountChanged: "Review Account Change…"
        case .massDelete: "Review Missing Items…"
        }
    }
}

/// `AccountChangeSheet` and `MassDeleteSheet`: a short explanation and the two ways out. Nothing is uploaded to a
/// different Apple Account, and nothing is deleted from iCloud, without the user choosing it here.
struct SyncQuestionSheet: View {
    let question: SyncQuestion
    /// "Keep sync paused": the root stops asking for this session.
    var onKeepPaused: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: question == .accountChanged ? "person.crop.circle.badge.questionmark" : "exclamationmark.icloud")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DS.Colour.accentText)
                .accessibilityHidden(true)
            Text(title)
                .font(DS.Typo.screenTitle)
                .tracking(-0.4)
                .foregroundStyle(DS.Colour.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(DS.Typo.subheadline)
                .lineSpacing(3)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(question == .massDelete)
        .sheetSizing(minWidth: 460, minHeight: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(question == .accountChanged ? AX.Sync.Account.sheet : AX.Sync.MassDelete.sheet)
    }

    private var held: Int { env.sync?.heldDeleteCount ?? 0 }

    private var title: String {
        switch question {
        case .accountChanged: SyncCopy.accountTitle
        case .massDelete: SyncCopy.massDeleteTitle(held)
        }
    }

    private var message: String {
        switch question {
        case .accountChanged: SyncCopy.accountMessage
        case .massDelete: SyncCopy.massDeleteMessage
        }
    }

    @ViewBuilder private var buttons: some View {
        switch question {
        case .accountChanged:
            PrimaryButton(SyncCopy.accountMerge) { resolve { await $0.resolveAccountChange(merge: true) } }
                .accessibilityIdentifier(AX.Sync.Account.merge)
            LinkButton(SyncCopy.accountKeepPaused, font: .system(size: 16, weight: .semibold)) {
                onKeepPaused()
                dismiss()
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(AX.Sync.Account.keepPaused)
        case .massDelete:
            // Restoring is the safe default; removing deletes the items from every device.
            PrimaryButton(SyncCopy.massDeleteRestore) { resolve { await $0.resolveMassDelete(confirm: false) } }
                .accessibilityIdentifier(AX.Sync.MassDelete.restore)
            Button(role: .destructive) {
                resolve { await $0.resolveMassDelete(confirm: true) }
            } label: {
                Text(SyncCopy.massDeleteConfirm(held))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.Colour.destructive)
                    .frame(maxWidth: .infinity, minHeight: DS.Space.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AX.Sync.MassDelete.confirm)
        }
    }

    private func resolve(_ work: @escaping @MainActor (SyncCoordinator) async -> Void) {
        guard let sync = env.sync else { dismiss(); return }
        dismiss()
        Task { await work(sync) }
    }
}

/// Shows the sync questions over the app's main window whenever sync pauses for one, once per pause.
struct SyncPrompts: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var question: SyncQuestion?
    @State private var declined: SyncQuestion?

    func body(content: Content) -> some View {
        content
            .onChange(of: env.sync?.status, initial: true) { _, status in update(status) }
            .sheet(item: $question) { q in
                SyncQuestionSheet(question: q, onKeepPaused: { declined = q })
            }
    }

    private func update(_ status: SyncStatus?) {
        let wanted = status.flatMap(SyncQuestion.init)
        if wanted == nil { declined = nil }
        if let wanted, wanted != declined, question == nil {
            question = wanted
        } else if wanted == nil, question != nil {
            question = nil
        }
    }
}

extension View {
    /// The account-change and mass-delete questions (§8.6), on the app's root view.
    func syncPrompts() -> some View { modifier(SyncPrompts()) }
}
