import SwiftUI

/// A respondent's Tapback sits on the opposite corner from the message's tail.
struct SceneMessageTapback: View {
    nonisolated enum Mark: Sendable {
        case heart, laugh, emphasize, question, thumbUp, thumbDown, emoji

        func emoji(in word: String?) -> String {
            switch self {
            case .heart: return "❤️"
            case .laugh: return "😂"
            case .emphasize: return "‼️"
            case .question: return "❓"
            case .emoji: return word ?? "✨"
            case .thumbUp, .thumbDown:
                let base: Unicode.Scalar = self == .thumbUp ? "👍" : "👎"
                // A written thumb and its skin tone form a single extended grapheme.
                if let thumb = word?.first(where: { $0.unicodeScalars.first == base }) { return String(thumb) }
                return String(base)
            }
        }
    }

    let mark: Mark
    let outgoingMessage: Bool
    var reactionWord: String? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: ThoughtBalloon { ThoughtBalloon(tailOnLeft: outgoingMessage) }
    private var blue: Color { Color(red: 0.015, green: 0.49, blue: 1) }
    private var graphite: Color { Color(white: 0.21) }

    var body: some View {
        ZStack {
            surface
            Text(verbatim: mark.emoji(in: reactionWord))
                .font(.custom("Apple Color Emoji", fixedSize: 17))
                .fixedSize()
                .position(x: outgoingMessage ? 16 : 14, y: 13.7)
        }
        .frame(width: 30, height: 35)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            shape.fill(outgoingMessage ? graphite : blue)
                .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 0.55) }
        } else if #available(macOS 26.0, *) {
            // The disc, little lobe and satellite share a single system glass surface.
            if outgoingMessage {
                Color.clear.glassEffect(.regular.tint(graphite.opacity(0.62)), in: shape)
            } else {
                // macOS desaturates tinted glass in a background player. A translucent
                // blue substrate preserves who reacted while the clear lens refracts it.
                Color.clear.glassEffect(.clear.tint(blue.opacity(0.75)), in: shape)
                    .background { shape.fill(blue.opacity(0.91)) }
                    .overlay {
                        shape.fill(LinearGradient(colors: [Color(red: 0.65, green: 0.91, blue: 1),
                                                          Color(red: 0.44, green: 0.76, blue: 1)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .opacity(0.29).blendMode(.plusLighter)
                    }
            }
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(outgoingMessage ? graphite.opacity(0.58) : blue.opacity(0.87)) }
                .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.55) }
        }
    }
}

nonisolated private struct ThoughtBalloon: Shape {
    let tailOnLeft: Bool

    func path(in rect: CGRect) -> Path {
        let disc = Path(ellipseIn: CGRect(x: 2.3, y: 0, width: 27.5, height: 27.5))
        let lobe = Path(ellipseIn: CGRect(x: 3.4, y: 22.1, width: 8.0, height: 8.0))
        var silhouette = disc.union(lobe)
        silhouette.addEllipse(in: CGRect(x: 0, y: 30.7, width: 3.9, height: 3.9))
        let scale = CGAffineTransform(scaleX: rect.width / 30, y: rect.height / 35)
        if !tailOnLeft {
            silhouette = silhouette.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 30, ty: 0))
        }
        return silhouette.applying(scale).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
