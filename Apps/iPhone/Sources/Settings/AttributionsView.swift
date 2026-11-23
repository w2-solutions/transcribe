import SwiftUI
import TranscribeCore
import TranscribeDesign

/// Acknowledgements (§6.10): credit, licence and source for every model and library the app runs.
struct AttributionsView: View {
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Transcribe runs these models and libraries on your iPhone.")
                    .font(DS.Typo.subheadline)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                ForEach(Attributions.all) { entry in
                    card(entry)
                }
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Attributions.screen)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .screenBackground()
    }

    private func card(_ entry: Attribution) -> some View {
        let isExpanded = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name)
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Colour.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                StatusPill(entry.licence, style: .accent)
            }
            Text(entry.notes)
                .font(DS.Typo.subheadline)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 0) {
                if let url = URL(string: entry.url) {
                    linkRow(Self.displayURL(entry.url), systemImage: "link", url: url)
                        .accessibilityLabel("Source: \(Self.displayURL(entry.url))")
                        .accessibilityIdentifier(AX.Attributions.link(entry.id))
                }
                if let licence = Attributions.licenceURL(for: entry.licence).flatMap(URL.init(string:)) {
                    linkRow("\(entry.licence) licence", systemImage: "doc.text", url: licence)
                        .accessibilityLabel("Read the \(entry.licence) licence")
                }
            }
            if let text = entry.licenceText {
                Button { withAnimation(.snappy) { toggle(entry.id) } } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "Hide licence text" : "Show full licence text")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colour.accentText)
                    .frame(minHeight: DS.Space.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(AX.Attributions.licenceToggle(entry.id))
                if isExpanded {
                    Text(Self.reflow(text))
                        .font(DS.Typo.caption)
                        .lineSpacing(2)
                        .foregroundStyle(DS.Colour.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Colour.neutralFill))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Attributions.entry(entry.id))
    }

    private func linkRow(_ title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                Text(title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DS.Colour.accentText)
            .frame(minHeight: DS.Space.hit)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Joins the hard-wrapped lines of a plain-text licence into flowing paragraphs so it wraps on a phone.
    static func reflow(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { para in
                para.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// "huggingface.co/nvidia/parakeet-tdt-0.6b-v3"
    static func displayURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}
