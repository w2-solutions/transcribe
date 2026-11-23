import SwiftUI

public struct IconTile: View {
    public enum Tint: Sendable { case neutral, accent }   // neutralFill + ink / accentFill + accentText
    let systemImage: String
    let tint: Tint
    public init(systemImage: String, tint: Tint) { self.systemImage = systemImage; self.tint = tint }   // 30 pt, radius 8, 16 pt symbol

    public var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.iconTile, style: .continuous)
            .fill(tint == .accent ? DS.Colour.accentFill : DS.Colour.neutralFill)
            .frame(width: DS.Size.iconTile, height: DS.Size.iconTile)
            .overlay {
                // Fitted into the mockup's 18 pt glyph box, so wide symbols keep a 6 pt margin in the tile.
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(tint == .accent ? DS.Colour.accentText : DS.Colour.ink)
            }
            .accessibilityHidden(true)
    }
}

public struct SettingsCard<Content: View>: View {
    /// Plain card radius 28, rows separated by dividers inset to the text column (58 pt).
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id {
                        Rectangle().fill(DS.Colour.divider).frame(height: 1).padding(.leading, 58)
                    }
                    subview
                }
            }
        }
        .cardSurface(padding: EdgeInsets())
    }
}

public struct ToggleRow: View {
    let systemImage: String
    let tint: IconTile.Tint
    let title: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    public init(systemImage: String, tint: IconTile.Tint, title: String, isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.systemImage = systemImage; self.tint = tint; self.title = title; self._isOn = isOn; self.isEnabled = isEnabled
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                IconTile(systemImage: systemImage, tint: tint)
                Text(title).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
            }
        }
        .toggleStyle(.switch)
        .tint(DS.Colour.accent)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(minHeight: DS.Size.settingsRow)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

public struct ValueRow: View {
    public enum Accessory: Sendable { case chevron, none, dots([Int]), menu }   // menu: up/down chevron (pop-up menu rows)   // dots: overlapping 10 pt slot dots with 2 pt white ring
    let systemImage: String
    let tint: IconTile.Tint
    let title: String
    let value: String?
    let accessory: Accessory
    let titleColor: Color

    public init(systemImage: String, tint: IconTile.Tint, title: String, value: String?, accessory: Accessory = .chevron,
                titleColor: Color = DS.Colour.ink) {
        self.systemImage = systemImage; self.tint = tint; self.title = title; self.value = value
        self.accessory = accessory; self.titleColor = titleColor
    }

    public var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: tint)
            Text(title).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(titleColor).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if case .dots(let slots) = accessory, !slots.isEmpty {
                    HStack(spacing: -2) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                            Circle().fill(SpeakerPalette.colour(slot: slot).dot)
                                .frame(width: 10, height: 10)
                                .overlay { Circle().stroke(Color.white, lineWidth: 2) }
                        }
                    }
                }
                if let value {
                    Text(value).font(.callout).foregroundStyle(DS.Colour.secondary).lineLimit(1)
                }
                switch accessory {
                case .chevron, .dots:
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Colour.chevron)
                case .menu:
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colour.secondary)
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(minHeight: DS.Size.settingsRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Settings rows") {
    @Previewable @State var identify = true
    @Previewable @State var recognise = true
    VStack(alignment: .leading, spacing: 6) {
        SectionHeader("Speakers", badge: "New")
        SettingsCard {
            ToggleRow(systemImage: "person.2.wave.2", tint: .accent, title: "Identify speakers", isOn: $identify)
            ToggleRow(systemImage: "person.crop.circle.badge.checkmark", tint: .accent, title: "Recognise saved voices",
                      isOn: $recognise, isEnabled: identify)
            ValueRow(systemImage: "person.2", tint: .accent, title: "Voices", value: "2 saved", accessory: .dots([0, 1]))
            ValueRow(systemImage: "clock", tint: .accent, title: "Run", value: "After recording", accessory: .none)
        }
    }
    .padding(16)
    .screenBackground()
}
