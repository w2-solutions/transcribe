import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screen 5 (§6.5): "Who is this?" (name a whole speaker) and "Who said this?" (correct a turn or speaker).
/// Presented by RootView as a sheet with the default glass background. Logic lives in `NameSpeakerModel`.
struct NameSpeakerSheet: View {
    let context: NameSpeakerContext
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model: NameSpeakerModel?

    init(context: NameSpeakerContext) { self.context = context }

    var body: some View {
        Group {
            if let model {
                NameSpeakerForm(model: model, audioURL: audioURL, onClose: { close() }, onSaved: { advance() },
                                onNotNow: { advance() })
            } else {
                Color.clear
            }
        }
        .presentationDetents([.custom(NameSheetDetent.self), .large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.NameSpeaker.sheet)
        .onAppear { if model == nil { model = makeModel() } }
        .onDisappear {
            if env.player.playingClipID != nil { env.player.pause() }
        }
    }

    private var recording: Recording? {
        let id = context.recordingID
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? env.container.mainContext.fetch(descriptor).first
    }

    private var audioURL: URL? { recording.map { env.paths.audioURL(fileName: $0.audioFileName) } }

    private func makeModel() -> NameSpeakerModel? {
        guard let recording else { return nil }
        let profiles = (try? env.container.mainContext.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        let mode: NameSpeakerModel.Mode
        switch context.mode {
        case .name: mode = .name
        case .correct(let turnID): mode = .correct(turnID: turnID)
        }
        return NameSpeakerModel(recording: recording, key: context.key, mode: mode, profiles: profiles)
    }

    private func close() { dismiss() }

    /// Next follow-up that still needs a name, else dismiss.
    private func advance() {
        let stillNeeding = Set(recording?.speakersNeedingName.map(\.key) ?? [])
        var remaining = context.followUps.filter { stillNeeding.contains($0) }
        guard !remaining.isEmpty else { dismiss(); return }
        let next = remaining.removeFirst()
        router.sheet = .nameSpeaker(NameSpeakerContext(recordingID: context.recordingID, key: next, mode: .name,
                                                       followUps: remaining))
    }
}

/// The sheet's content, bound to the model.
private struct NameSpeakerForm: View {
    @Bindable var model: NameSpeakerModel
    let audioURL: URL?
    let onClose: () -> Void
    let onSaved: () -> Void
    let onNotNow: () -> Void
    @Environment(AppEnvironment.self) private var env
    @FocusState private var nameFocused: Bool
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let prompt = model.askPrompt {
                    // The suggested voice was learned on another device (§7): say why this is only a question.
                    Text(prompt)
                        .scaledFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(DS.Colour.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .padding(.leading, 2)
                        .accessibilityIdentifier(AX.NameSpeaker.askPrompt)
                }
                if !model.clips.isEmpty {
                    listen.padding(.top, 16)
                }
                nameSection.padding(.top, 16)
                savedVoices.padding(.top, 16)
                if model.showsScope {
                    scope.padding(.top, 16)
                }
                if model.showsRemember {
                    rememberCard.padding(.top, 14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) { buttons }
        .task {
            // Focus once the sheet has settled (the mockup shows the field focused).
            try? await Task.sleep(for: .milliseconds(350))
            nameFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    subjectDot
                    Text("\(Text(model.subtitlePrefix))\(Text(model.spokeFor).font(.system(.footnote, design: .monospaced).weight(.medium)))")
                        .font(DS.Typo.chip)
                        .foregroundStyle(DS.Colour.secondary)
                }
                .accessibilityElement(children: .ignore)
                // UI tests read the label: keep it identical to the visible "Speaker 2 · spoke for 0:13".
                .accessibilityLabel(model.subtitle)
                .accessibilityIdentifier(AX.NameSpeaker.subtitle)
                Text(model.title)
                    .font(DS.Typo.screenTitle)
                    .tracking(-0.5)
                    .foregroundStyle(DS.Colour.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AX.NameSpeaker.title)
            }
            .padding(.leading, 2)
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark", accessibilityLabel: "Close", action: onClose)
                .accessibilityIdentifier(AX.NameSpeaker.closeButton)
        }
    }

    @ViewBuilder private var subjectDot: some View {
        if model.subject.label == .unnamed || model.subject.label == .suggested {
            Circle()
                .fill(SpeakerPalette.unnamed.fill)
                .overlay { Circle().strokeBorder(DS.Colour.unnamed, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])) }
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        } else {
            SpeakerDot(slot: model.subject.slot)
        }
    }

    // MARK: Listen

    private var listen: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Listen")
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, clip in
                ClipRow(quote: clip.quote, duration: clip.range.duration, slot: model.subject.slot, peaks: clip.peaks,
                        isPlaying: env.player.playingClipID == clip.id) {
                    toggleClip(clip)
                }
                .accessibilityIdentifier(AX.NameSpeaker.clip(i))
            }
        }
    }

    private func toggleClip(_ clip: NameSpeakerModel.Clip) {
        guard let audioURL else { return }
        if env.player.playingClipID == clip.id {
            env.player.pause()
        } else {
            env.player.playClip(url: audioURL, range: clip.range, id: clip.id)
        }
    }

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Name")
            ZStack(alignment: .leading) {
                TextField("Name", text: $model.name)
                    .scaledFont(size: 20, weight: .semibold, relativeTo: .title3)
                    .tracking(-0.2)
                    .foregroundStyle(DS.Colour.ink)
                    .autocorrectionDisabled()
                    .inputCapitalization(.words)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .padding(.leading, 40)
                    .padding(.trailing, 52)
                    .frame(minHeight: 56)
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier(AX.NameSpeaker.nameField)
                SpeakerDot(slot: model.fieldSlot, diameter: 10)
                    .padding(.leading, 18)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                if !model.name.isEmpty {
                    Button {
                        model.clearName()
                        nameFocused = true
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(DS.Colour.secondary)
                            .frame(width: DS.Space.hit, height: DS.Space.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .accessibilityLabel("Clear name")
                    .accessibilityIdentifier(AX.NameSpeaker.clearName)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Colour.fieldFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder(nameFocused ? DS.Colour.accent : DS.Colour.chipStroke, lineWidth: nameFocused ? 1.5 : 1)
            }
            .background {
                if nameFocused {
                    RoundedRectangle(cornerRadius: DS.Radius.field + 4, style: .continuous)
                        .stroke(DS.Colour.accent.opacity(0.14), lineWidth: 4)
                        .padding(-2)
                }
            }
            .animation(.easeOut(duration: 0.15), value: nameFocused)
            if let error {
                Text(error)
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.destructive)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: Saved voices

    private var savedVoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Saved voices")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(model.profiles) { profile in
                    profileChip(profile)
                }
                ForEach(model.otherSpeakers) { speaker in
                    speakerChip(speaker)
                }
                newPersonChip
            }
        }
    }

    private func profileChip(_ profile: NameSpeakerModel.ProfileOption) -> some View {
        let selected = model.selection == .profile(profile.id)
        let palette = SpeakerPalette.colour(slot: profile.slot)
        return Button {
            model.select(.profile(profile.id))
            nameFocused = false
        } label: {
            HStack(spacing: 7) {
                SpeakerDot(slot: profile.slot)
                Text("\(Text(profile.name))\(Text(profile.isMe ? " (You)" : "").fontWeight(.medium))")
                    .lineLimit(1)
            }
            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(palette.text)
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(minHeight: DS.Space.hit)
            .background { chipBackground(selected: selected, fill: palette.fill) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.isMe ? "\(profile.name) (You)" : profile.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AX.NameSpeaker.savedVoice(profile.slug))
    }

    private func speakerChip(_ speaker: NameSpeakerModel.SpeakerOption) -> some View {
        let selected = model.selection == .speaker(speaker.key)
        let palette = SpeakerPalette.colour(slot: speaker.slot)
        return Button {
            model.select(.speaker(speaker.key))
            nameFocused = false
        } label: {
            HStack(spacing: 7) {
                SpeakerDot(slot: speaker.slot)
                Text(speaker.name).lineLimit(1)
            }
            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(selected ? DS.Colour.ink : (speaker.hasName ? palette.text : DS.Colour.unnamedText))
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(minHeight: DS.Space.hit)
            .background {
                if selected {
                    chipBackground(selected: true, fill: .clear)
                } else if speaker.hasName {
                    chipBackground(selected: false, fill: palette.fill)
                } else {
                    Capsule(style: .continuous)
                        .strokeBorder(DS.Colour.unnamed, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Same as \(speaker.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AX.NameSpeaker.sameAsSpeaker(speaker.ordinal))
    }

    private var newPersonChip: some View {
        let selected = model.selection == .newPerson
        return Button {
            model.select(.newPerson)
            nameFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                Text("New person")
            }
            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(DS.Colour.ink)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(minHeight: DS.Space.hit)
            .background {
                if selected {
                    chipBackground(selected: true, fill: .clear)
                } else {
                    Capsule(style: .continuous).fill(DS.Colour.chipFill)
                        .overlay { Capsule(style: .continuous).strokeBorder(DS.Colour.chipStroke, lineWidth: 1) }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New person")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AX.NameSpeaker.newPerson)
    }

    /// Unselected: slot fill with a 1 pt white 85% border. Selected: field fill (white 80%) with a 1.5 pt ink border.
    @ViewBuilder
    private func chipBackground(selected: Bool, fill: Color) -> some View {
        if selected {
            Capsule(style: .continuous).fill(DS.Colour.fieldFill)
                .overlay { Capsule(style: .continuous).strokeBorder(DS.Colour.ink, lineWidth: 1.5) }
        } else {
            Capsule(style: .continuous).fill(fill)
                .overlay { Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.85), lineWidth: 1) }
        }
    }

    // MARK: Scope

    private var scope: some View {
        Picker("Change", selection: $model.scope) {
            Text(model.allTurnsTitle).tag(NameSpeakerModel.Scope.allTurns)
            Text("Just this turn").tag(NameSpeakerModel.Scope.justThisTurn)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AX.NameSpeaker.scopePicker)
    }

    // MARK: Remember

    private var rememberCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Remember this voice")
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .callout)
                    .foregroundStyle(DS.Colour.ink.opacity(model.rememberEnabled ? 1 : 0.5))
                Spacer(minLength: 0)
                Toggle("Remember this voice", isOn: rememberBinding)
                    .labelsHidden()
                    .tint(DS.Colour.accent)
                    .disabled(!model.rememberEnabled)
                    .accessibilityIdentifier(AX.NameSpeaker.rememberToggle)
            }
            .frame(minHeight: DS.Space.hit)
            Text(model.rememberHelp)
                .font(DS.Typo.meta)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .padding(.trailing, 8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AX.NameSpeaker.rememberHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 14), radius: DS.Radius.row)
    }

    /// Shows off (and stays off) when the voice can't be remembered.
    private var rememberBinding: Binding<Bool> {
        Binding(get: { model.rememberEffective }, set: { model.remember = $0 })
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 2) {
            PrimaryButton(model.saveTitle) { save() }
                .disabled(!model.canSave)
                .shadow(color: DS.Colour.ink.opacity(model.canSave ? 0.18 : 0), radius: 11, x: 0, y: 8)
                .accessibilityIdentifier(AX.NameSpeaker.saveButton)
            LinkButton("Not now", font: .system(size: 16, weight: .semibold), action: onNotNow)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AX.NameSpeaker.notNowButton)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        // "Not now" is a 44 pt target with centred text; let its lower half sit over the home-indicator inset
        // so the 0.76 detent shows the whole form, as in the mockup.
        .padding(.bottom, -14)
    }

    private func save() {
        do {
            try model.save(using: env.store)
            error = nil
            if env.player.playingClipID != nil { env.player.pause() }
            onSaved()
        } catch {
            self.error = NameSpeakerModel.message(for: error)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Typo.chip)
            .foregroundStyle(DS.Colour.secondary)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The sheet's first height: the mockup's 640 pt (LabelSpeaker), or the whole height on smaller screens.
/// A fraction would measure against the safe-area height and come out about 55 pt short on iPhone 15.
struct NameSheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? { Swift.min(context.maxDetentValue, 640) }
}
