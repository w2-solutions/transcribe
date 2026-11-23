import SwiftUI

public struct SectionHeader: View {
    let title: String
    let badge: String?
    /// uppercase 13 semibold, padding 0 16
    public init(_ title: String, badge: String? = nil) { self.title = title; self.badge = badge }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(DS.Typo.sectionHeader)
                .tracking(0.4)
                .foregroundStyle(DS.Colour.secondary)
            if let badge { StatusPill(badge, style: .accent, compact: true) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Section header") {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Speakers", badge: "New")
        SectionHeader("Saved")
    }
    .padding()
}
