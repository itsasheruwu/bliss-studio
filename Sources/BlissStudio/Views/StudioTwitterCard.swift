import SwiftUI

/// The two parts of the preview match the link attachment in Messages.
/// All information is local. Opening the link is a separate user action.
struct StudioTwitterCard: View {
    static let destination = URL(string: "https://twitter.com")!

    let side: CGFloat

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: side * 0.064, style: .continuous)
        Link(destination: Self.destination) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color(white: 8 / 255)
                    XMark()
                        .fill(Color.white, style: FillStyle(eoFill: true))
                        .frame(width: side * 0.612, height: side * 0.555)
                }
                .frame(width: side, height: side)
                VStack(alignment: .leading, spacing: max(1, side * 0.008)) {
                    Text(verbatim: "X. It’s what’s happening")
                        .font(.system(size: max(10, side * 0.046), weight: .semibold))
                        .foregroundStyle(Color(white: 0.87))
                        .lineLimit(2)
                    Text(verbatim: "twitter.com")
                        .font(.system(size: max(9, side * 0.041)))
                        .foregroundStyle(Color(white: 0.62))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, max(7, side * 0.038))
                .padding(.vertical, max(5, side * 0.025))
            }
            .frame(width: side, alignment: .leading)
            .background(Color(white: 34 / 255))
            .clipShape(outline)
            .overlay { outline.strokeBorder(.white.opacity(0.07), lineWidth: 0.5).allowsHitTesting(false) }
            .contentShape(outline)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("X. It’s what’s happening, twitter.com")
    }

    nonisolated private struct XMark: Shape {
        func path(in rect: CGRect) -> Path {
            var mark = Path()
            mark.addLines([
                CGPoint(x: 0.788, y: 0), CGPoint(x: 0.942, y: 0), CGPoint(x: 0.607, y: 0.424),
                CGPoint(x: 1, y: 1), CGPoint(x: 0.691, y: 1), CGPoint(x: 0.450, y: 0.650),
                CGPoint(x: 0.173, y: 1), CGPoint(x: 0.020, y: 1), CGPoint(x: 0.379, y: 0.547),
                CGPoint(x: 0, y: 0), CGPoint(x: 0.316, y: 0), CGPoint(x: 0.535, y: 0.320),
            ])
            mark.closeSubpath()
            mark.addLines([
                CGPoint(x: 0.734, y: 0.902), CGPoint(x: 0.819, y: 0.902),
                CGPoint(x: 0.270, y: 0.096), CGPoint(x: 0.179, y: 0.096),
            ])
            mark.closeSubpath()
            return mark.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width, y: rect.height))
        }
    }
}
