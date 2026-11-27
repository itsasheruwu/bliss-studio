import SwiftUI

/// All motion is sampled from the playback clock so a pause or a backwards seek
/// reproduces the same stamp, ink reveal and echo at the same sung word.
struct SceneLyricPerformance: ViewModifier {
    let message: StudioLyricScore.Message
    let time: Double
    let current: Bool
    let reduceMotion: Bool
    let compact: Bool

    func body(content: Content) -> some View {
        let effect = current && !reduceMotion ? message.bubbleEffect(at: time) : nil
        let age = max(0, time - (effect?.start ?? time))
        let slam = effect?.kind == .slam ? cos(age * 21) * exp(-age * 7.5) : 0
        let loud = effect?.kind == .loud ? sin(age * 22) * exp(-age * 5) : 0
        let gentle = effect?.kind == .gentle ? pow(max(0, 1 - age / 0.70), 2) : 0
        let tap = effect?.kind == .stutter ? sin(age * 27) * exp(-age * 4.2) : 0
        let reaction = message.reaction(at: time)
        let right = message.right
        let stickerSize: CGFloat = compact ? 53 : 67
        content
            .overlay {
                if let effect, effect.kind == .invisibleInk || effect.kind == .spotlight {
                    surface(effect.kind, age: age)
                }
            }
            .opacity(1 - 0.62 * gentle)
            .scaleEffect(x: 1 + 0.095 * slam - 0.04 * tap + 0.14 * loud - 0.18 * gentle,
                         y: 1 - 0.075 * slam + 0.10 * tap + 0.16 * loud - 0.18 * gentle,
                         anchor: right ? .bottomTrailing : .bottomLeading)
            .offset(x: 5 * loud, y: -5 * abs(tap) + 3 * slam + 4 * gentle)
            .overlay(alignment: right ? .topLeading : .topTrailing) {
                if let reaction {
                    let age = max(0, time - reaction.start)
                    if reaction.kind == .slowSilver {
                        SceneSlowSilverSticker(age: age, messageRight: right, compact: compact, reduceMotion: reduceMotion)
                            .frame(width: stickerSize, height: stickerSize)
                            .offset(x: right ? -11 : 11, y: -stickerSize * 0.63)
                    } else if let mark = tapbackMark(reaction.kind) {
                        let spring = reduceMotion ? 0 : exp(-9 * age) * cos(15 * age)
                        SceneMessageTapback(mark: mark, outgoingMessage: right, reactionWord: reaction.word)
                            .scaleEffect(1 - 0.55 * spring, anchor: right ? .bottomTrailing : .bottomLeading)
                            .rotationEffect(.degrees((right ? -13 : 13) * spring))
                            .offset(x: right ? -12 : 12, y: -21)
                    }
                }
            }
            .padding(.top, message.sceneEvents.contains { $0.kind == .slowSilver } ? stickerSize * 0.61 : reaction == nil ? 0 : 20)
    }

    @ViewBuilder private func surface(_ kind: StudioLyricEvent.Kind, age: Double) -> some View {
        Canvas { context, size in
            let p = min(1, age / 1.15)
            if kind == .spotlight {
                let center = CGPoint(x: size.width * (0.12 + 0.85 * p), y: size.height * 0.5)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.36 * sin(.pi * p)), .clear]),
                    center: center, startRadius: 0, endRadius: size.height * 1.05))
            } else {
                // A brushed patch of silver grain clears from left to right.
                for n in 0..<190 {
                    let i = Double(n + 1)
                    let x = (i * 0.618034).truncatingRemainder(dividingBy: 1)
                    let y = (i * 0.414214 + 0.12 * sin(i)).truncatingRemainder(dividingBy: 1)
                    let reveal = max(0, min(1, (x - p * 1.32 + 0.17) * 4))
                    let radius = 0.55 + 0.65 * (0.5 + 0.5 * sin(2.7 * i))
                    let dot = CGRect(x: x * size.width + sin(i + 3 * age) * 2,
                                     y: y * size.height, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(reveal * 0.66)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tapbackMark(_ kind: StudioLyricEvent.Kind) -> SceneMessageTapback.Mark? {
        switch kind {
        case .heart: .heart
        case .emoji: .emoji
        case .question: .question
        case .emphasize: .emphasize
        case .laugh: .laugh
        case .thumbUp: .thumbUp
        case .thumbDown: .thumbDown
        default: nil
        }
    }
}

/// The Messages Echo effect sends copies into the open side of the conversation.
/// Draw only the word being echoed, with the real lyric bubble always in front.
struct SceneConversationEcho: View {
    let event: StudioLyricEvent
    let age: Double
    let right: Bool

    var body: some View {
        Canvas { context, size in
            let word = Text(verbatim: String(event.word.trimmingCharacters(in: .punctuationCharacters).prefix(64)))
                .font(.system(size: min(18, max(13, size.width / 49)), weight: .medium))
                .foregroundStyle(.white)
            let resolved = context.resolve(word)
            let ink = resolved.measure(in: size)
            let bounds = CGRect(x: -ink.width / 2 - 9, y: -ink.height / 2 - 4,
                                width: ink.width + 18, height: ink.height + 8)
            let origin = CGPoint(x: size.width * (right ? 0.66 : 0.34), y: size.height * 0.57)
            for index in 0..<6 {
                let i = Double(index)
                let t = (age - i * 0.057) / 0.90
                guard t > 0 && t < 1 else { continue }
                let travel = 1 - pow(1 - t, 2)
                let distance = size.width * (0.27 + 0.053 * i) * travel
                let rise = [-0.35, 0.15, -0.19, 0.30, -0.46, -0.03][index] * size.height * travel
                var layer = context
                layer.translateBy(x: origin.x + (right ? -distance : distance), y: origin.y + rise)
                let scale = 0.66 + 0.37 * travel - i * 0.025
                layer.scaleBy(x: scale, y: scale)
                layer.rotate(by: .degrees((i - 2) * 2 * travel))
                layer.opacity = min(1, t / 0.13) * min(1, (1 - t) / 0.38) * (0.82 - i * 0.05)
                layer.fill(Path(roundedRect: bounds, cornerRadius: 12),
                           with: .color(right ? Color(red: 0.07, green: 0.42, blue: 0.89) : Color(white: 0.27)))
                layer.draw(resolved, at: .zero)
            }
        }
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}
