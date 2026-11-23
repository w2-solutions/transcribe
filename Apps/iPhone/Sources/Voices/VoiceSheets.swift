import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

// MARK: - Edit

/// Rename a voice and mark it as "me" (only one profile can be me).
struct VoiceEditSheet: View {
    let profileID: UUID
    let initialName: String
    let initialIsMe: Bool
    let otherNames: [String]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isMe: Bool
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    init(profileID: UUID, initialName: String, initialIsMe: Bool, otherNames: [String]) {
        self.profileID = profileID
        self.initialName = initialName
        self.initialIsMe = initialIsMe
        self.otherNames = otherNames
        _name = State(initialValue: initialName)
        _isMe = State(initialValue: initialIsMe)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool {
        otherNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
    private var canSave: Bool { !trimmed.isEmpty && !isDuplicate && (trimmed != initialName || isMe != initialIsMe) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name").font(DS.Typo.chip).foregroundStyle(DS.Colour.secondary).padding(.horizontal, 4)
                    TextField("Name", text: $name)
                        .font(.title3.weight(.semibold))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { if canSave { save() } }
                        .padding(.horizontal, 18)
                        .frame(height: 56)
                        .background {
                            RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Colour.fieldFill)
                                .overlay {
                                    RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                                        .strokeBorder(nameFocused ? DS.Colour.accent : DS.Colour.chipStroke, lineWidth: nameFocused ? 1.5 : 1)
                                }
                        }
                        .accessibilityIdentifier(AX.VoiceDetail.Edit.nameField)

                    if isDuplicate {
                        Text("There's already a voice called \(trimmed). Use Merge to combine them.")
                            .font(DS.Typo.meta).foregroundStyle(DS.Colour.destructive).padding(.horizontal, 4)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: $isMe) {
                            Text("This is me").font(.callout.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                        }
                        .toggleStyle(.switch)
                        .tint(DS.Colour.accent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(AX.VoiceDetail.Edit.isMeToggle)
                        Text("Your own voice is listed first and labelled You.")
                            .font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                    }
                    .cardSurface(padding: EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 14), radius: DS.Radius.row)
                    .padding(.top, 10)

                    if let errorText {
                        Text(errorText).font(DS.Typo.meta).foregroundStyle(DS.Colour.destructive).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Edit voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .tint(DS.Colour.ink)
                        .accessibilityIdentifier(AX.VoiceDetail.Edit.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier(AX.VoiceDetail.Edit.saveButton)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.VoiceDetail.Edit.sheet)
    }

    private func save() {
        do {
            if trimmed != initialName { try env.store.renameProfile(profileID: profileID, name: trimmed) }
            if isMe != initialIsMe { try env.store.setIsMe(profileID: isMe ? profileID : nil) }
            dismiss()
        } catch {
            errorText = VoiceDetailView.describe(error)
        }
    }
}

// MARK: - Merge

/// Pick the voice to merge this one into, then confirm.
struct VoiceMergeSheet: View {
    let profileID: UUID
    let onMerged: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [VoiceProfile]
    @State private var target: VoiceProfile?
    @State private var errorText: String?

    private var source: VoiceProfile? { profiles.first { $0.id == profileID } }
    private var targets: [VoiceProfile] { VoicesListModel.sortedProfiles(profiles.filter { $0.id != profileID }) }

    var body: some View {
        let sourceName = source?.name ?? "This voice"
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose the voice to keep. \(sourceName)'s samples and recordings move to it.")
                        .font(.subheadline).foregroundStyle(DS.Colour.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    if targets.isEmpty {
                        Text("No other saved voices.")
                            .font(.subheadline).foregroundStyle(DS.Colour.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface()
                    } else {
                        DividedCard(dividerInset: 74) {
                            ForEach(targets) { p in
                                Button { target = p } label: {
                                    HStack(spacing: 14) {
                                        VoiceAvatar(initial: p.initial, slot: p.colourSlot)
                                        Text(p.name).font(DS.Typo.headline).foregroundStyle(DS.Colour.ink)
                                        if p.isMe { StatusPill("You", compact: true) }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 64)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Merge into \(p.name)")
                                .accessibilityIdentifier(AX.VoiceDetail.Merge.target(AX.slug(p.name)))
                                // Anchored to the row so the iOS 27 popover points at the chosen voice.
                                .confirmationDialog("Merge \(sourceName) into \(p.name)?",
                                                    isPresented: Binding(get: { target?.id == p.id },
                                                                         set: { if !$0 { target = nil } }),
                                                    titleVisibility: .visible) {
                                    Button("Merge") { merge(into: p) }
                                        .accessibilityIdentifier(AX.VoiceDetail.Merge.confirm)
                                    Button("Cancel", role: .cancel) { target = nil }
                                } message: {
                                    Text("\(sourceName)'s samples and recordings move to \(p.name).")
                                }
                            }
                        }
                    }
                    if let errorText {
                        Text(errorText).font(DS.Typo.meta).foregroundStyle(DS.Colour.destructive).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Merge \(sourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .tint(DS.Colour.ink)
                        .accessibilityIdentifier(AX.VoiceDetail.Merge.cancelButton)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.VoiceDetail.Merge.sheet)
    }

    private func merge(into t: VoiceProfile) {
        let targetID = t.id
        env.player.stop()
        do {
            try env.store.mergeProfiles(source: profileID, into: targetID)
            onMerged()
        } catch {
            errorText = VoiceDetailView.describe(error)
        }
    }
}

// MARK: - Add sample

/// Speakers in other recordings with enough clear speech to add as a sample of this voice.
struct VoiceAddSampleSheet: View {
    let profileID: UUID
    /// Called with the toast text once a candidate was tried.
    let onFinished: (String) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [SampleCandidate]?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick a speaker who is this person. Their clear speech becomes another sample.")
                        .font(.subheadline).foregroundStyle(DS.Colour.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    if let candidates {
                        if candidates.isEmpty {
                            Text("No other recordings with enough clear speech.")
                                .font(.subheadline).foregroundStyle(DS.Colour.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .cardSurface()
                                .accessibilityIdentifier(AX.VoiceDetail.AddSample.emptyState)
                        } else {
                            DividedCard(dividerInset: 16) {
                                ForEach(Array(candidates.enumerated()), id: \.element.id) { i, c in
                                    candidateRow(c, index: i)
                                }
                            }
                        }
                    } else if errorText == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    if let errorText {
                        Text(errorText).font(DS.Typo.meta).foregroundStyle(DS.Colour.destructive).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Add a sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .tint(DS.Colour.ink)
                        .accessibilityIdentifier(AX.VoiceDetail.AddSample.cancelButton)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.VoiceDetail.AddSample.sheet)
        .task { load() }
    }

    private func candidateRow(_ c: SampleCandidate, index i: Int) -> some View {
        let detail = "\(c.recordingTitle) · \(DisplayFormat.duration(c.cleanSeconds)) of speech"
        return Button { add(c) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.speakerName).font(.callout.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                    Text(detail).font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.Colour.accent)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.speakerName) · \(detail)")
        .accessibilityHint("Adds this speaker as a sample")
        .accessibilityIdentifier(AX.VoiceDetail.AddSample.candidate(i))
    }

    private func load() {
        do {
            candidates = try env.store.sampleCandidates(for: profileID)
        } catch {
            errorText = VoiceDetailView.describe(error)
        }
    }

    private func add(_ c: SampleCandidate) {
        do {
            let result = try env.store.addSample(profileID: profileID, fromSpeaker: c.id)
            onFinished(Self.message(for: result))
        } catch {
            errorText = VoiceDetailView.describe(error)
        }
    }

    static func message(for result: NameResult) -> String {
        if result.sampleStored { return "Sample added" }
        switch result.skipReason {
        case .duplicate: return "Already have a sample like this"
        case .tooLittleSpeech: return "Needs about 10 seconds of clear speech"
        case .noVector: return "No voice data in that recording"
        case .rememberOff, nil: return "Sample not added"
        }
    }
}
