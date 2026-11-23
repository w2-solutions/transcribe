import SwiftUI

/// A system font at a mockup point size that still follows Dynamic Type: the size scales with `relativeTo`
/// exactly as that text style does (14 pt next to `.subheadline`, 20 pt next to `.title3`, …).
/// Use it instead of `.font(.system(size:))` on text (§6.0 "Use DS.Typo text styles so Dynamic Type works").
public struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    public init(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    public func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

public extension View {
    /// `.font(.system(size:weight:))` that scales with Dynamic Type relative to `style`.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}
