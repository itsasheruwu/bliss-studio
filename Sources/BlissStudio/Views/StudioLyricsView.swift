import SwiftUI

struct StudioLyricsView: View {
    let session: StudioSession
    let palette: StudioPalette
    let availableSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var score = StudioLyricScore()

    private struct Input: Equatable {
        let lines: [StudioLine]
        let title: String
        let artist: String
        let duration: Double
        let effects: StudioEffectsGraph?
    }

    var body: some View {
        Group {
            if session.lyrics.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 23, weight: .light)).foregroundStyle(palette.highlight)
                    Text(session.lyricsStatus)
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center).frame(maxWidth: 340)
                    HStack(spacing: 12) {
                        Button("Import lyrics…", action: session.importLyrics)
                        Button("Retry", action: session.retryLyrics)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                TimelineView(.animation(minimumInterval: reduceMotion ? 0.12 : 1 / 30.0,
                                        paused: session.track?.isPlaying != true)) { clock in
                    StudioLyricThread(
                        score: score, time: session.position(at: clock.date) + session.lyricOffset,
                        palette: palette, availableSize: availableSize, reduceMotion: reduceMotion,
                        performanceAccent: reduceMotion ? 0 : session.performanceAccent
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 2) {
                    if session.lyrics.first?.isEstimated == true {
                        Text("Estimated timing").font(.caption).foregroundStyle(.white.opacity(0.67))
                            .help("These lyrics have no timestamps. Bliss Studio estimates their pace from the text and song length.")
                    }
                }
            }
        }
        .onChange(of: Input(lines: session.lyrics, title: session.track?.title ?? "", artist: session.track?.artist ?? "",
                            duration: session.track?.duration ?? 0, effects: session.lyricEffects),
                  initial: true) { _, input in
            score = StudioLyricScore(lines: input.lines, title: input.title, artist: input.artist, duration: input.duration, effects: input.effects)
        }
    }
}

struct StudioLyricThread: View {
    let score: StudioLyricScore
    let time: Double
    let palette: StudioPalette
    let availableSize: CGSize
    let reduceMotion: Bool
    var performanceAccent: Double = 0

    private var compact: Bool { availableSize.height < 560 }

    var body: some View {
        GeometryReader { space in
            let width = min(590, min(space.size.width - 24, availableSize.width * 0.79))
            ZStack {
                if let active = score.activeIndex(at: time), !score.isInterlude(after: active, at: time) {
                    if !reduceMotion {
                        SceneLyricScreenEffects(message: score.messages[active], time: time)
                    }
                    if !reduceMotion, let echo = score.messages[active].echo(at: time) {
                        SceneConversationEcho(event: echo, age: time - echo.start, right: score.messages[active].right)
                    }
                    ViewThatFits(in: .vertical) {
                        if !compact { messages(through: active, previous: 2, width: width, height: space.size.height) }
                        messages(through: active, previous: 1, width: width, height: space.size.height)
                        messages(through: active, previous: 0, width: width, height: space.size.height)
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: active)
                } else {
                    let label = score.estimatedTiming ? "Lyric break" :
                        (score.activeIndex(at: time) == nil ? "Instrumental intro" : "Instrumental")
                    Label(label, systemImage: "waveform")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func messages(through active: Int, previous: Int, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(max(0, active - previous)...active, id: \.self) { index in
                let message = score.messages[index]
                let current = index == active
                let groupEnd = current || score.messages[index + 1].right != message.right
                let grouped = index > 0 && score.messages[index - 1].right == message.right
                HStack(spacing: 0) {
                    if message.right { Spacer(minLength: width * 0.07) }
                    StudioLyricBubble(message: message, time: time, current: current, groupEnd: groupEnd,
                                          compact: compact, maxWidth: width * 0.89, viewportHeight: height,
                                          fontSize: min(compact ? 20 : 28, max(17, availableSize.width / 40)),
                                          reduceMotion: reduceMotion, palette: palette, performanceAccent: performanceAccent)
                    if !message.right { Spacer(minLength: width * 0.07) }
                }
                .padding(.top, index == max(0, active - previous) ? 0 : (grouped ? 3 : 13))
                .opacity(current ? 1 : (index + 1 == active ? 0.72 : 0.42))
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                                                   removal: .opacity.combined(with: .offset(y: -8))))
            }
        }
        .frame(width: max(1, width))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StudioLyricBubble: View {
    let message: StudioLyricScore.Message
    let time: Double
    let current: Bool
    let groupEnd: Bool
    let compact: Bool
    let maxWidth: CGFloat
    let viewportHeight: CGFloat
    let fontSize: CGFloat
    let reduceMotion: Bool
    let palette: StudioPalette
    let performanceAccent: Double

    private var count: Int { reduceMotion ? message.words.count : message.visibleWordCount(at: time) }
    private var hasCue: Bool { time >= message.motifStart }
    private var hasMap: Bool { hasCue && message.motif?.placeName != nil }
    private var hasTwitterLink: Bool { message.twitterLinkStart.map { time >= $0 } ?? false }
    private var showsHeart: Bool { current && hasCue && message.motif == .heart && message.reaction(at: time) == nil }
    private var shape: SceneBubbleShape { .init(right: message.right, tail: groupEnd) }
    private var fill: Color {
        if let tint = message.bubbleTint(at: time) { return tint.bubbleColor }
        return message.right ? Color(red: 0.045, green: 0.43, blue: 0.91) : Color(white: 0.171)
    }
    private var accessibilityText: String {
        var label = message.text
        if hasCue, let name = message.motif?.placeName { label += ". Map of \(name)" }
        switch message.reaction(at: time)?.kind {
        case .heart: label += ". Heart reaction"
        case .emoji: label += ". Reaction " + (message.reaction(at: time)?.word ?? "")
        case .slowSilver: label += ". Slow Silver 03 sticker"
        case .question: label += ". Question mark reaction"
        case .emphasize: label += ". Emphasized reaction"
        case .laugh: label += ". Laugh reaction"
        case .thumbUp: label += ". Thumbs up reaction"
        case .thumbDown: label += ". Thumbs down reaction"
        default: if showsHeart { label += ". Heart reaction" }
        }
        if message.block(.reply, at: time) != nil, let quote = message.quotedLyric { label += ". In reply to " + quote }
        if let sticker = message.block(.emojiSticker, at: time) { label += ". Sticker " + sticker.glyph }
        if let sticker = message.block(.imageSticker, at: time), message.stickerImages[sticker.id] != nil { label += ". Image sticker" }
        if message.block(.read, at: time) != nil { label += ". Read" }
        else if message.block(.delivered, at: time) != nil { label += ". Delivered" }
        return label
    }

    var body: some View {
        VStack(alignment: message.right ? .trailing : .leading, spacing: 4) {
            if message.block(.reply, at: time) != nil, let quote = message.quotedLyric {
                Label {
                    Text(quote).lineLimit(1)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.74))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: maxWidth, alignment: message.right ? .trailing : .leading)
                .accessibilityLabel("Reply to " + quote)
            }
            bubbleContent
                .overlay(alignment: message.right ? .bottomLeading : .bottomTrailing) {
                    if let sticker = message.block(.imageSticker, at: time), let image = message.stickerImages[sticker.id] {
                        stickerDecoration(sticker) {
                            Image(decorative: image, scale: 1)
                                .resizable().scaledToFit().frame(width: compact ? 35 : 47, height: compact ? 35 : 47)
                        }
                    } else if let sticker = message.block(.emojiSticker, at: time) {
                        stickerDecoration(sticker) { Text(sticker.glyph).font(.system(size: compact ? 27 : 35)) }
                    }
                }
            detailFooter
        }
        .accessibilityElement(children: hasMap || hasTwitterLink ? .contain : .ignore)
        .accessibilityAddTraits(hasMap || hasTwitterLink ? [] : .isStaticText)
        .accessibilityLabel(accessibilityText)
    }

    private func stickerDecoration(_ block: StudioEffectsGraph.Block, @ViewBuilder content: () -> some View) -> some View {
        let age = max(0, time - message.cueStart - block.delay)
        return content()
            .rotationEffect(.degrees(message.right ? -13 : 13))
            .scaleEffect(reduceMotion ? 1 : 1 - 0.34 * exp(-age * 8) * cos(age * 18))
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .offset(x: message.right ? -12 : 12, y: 10)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var detailFooter: some View {
        if let typing = message.block(.typing, at: time), current, time - message.cueStart - typing.delay < 1.2 {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let phase = (time - message.cueStart - typing.delay) * 9 - Double(i) * 1.18
                    Circle()
                        .fill(.white.opacity(reduceMotion ? 0.64 : 0.56 + 0.34 * sin(phase)))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.13), in: Capsule())
            .accessibilityLabel("Typing")
        }
        if message.block(.read, at: time) != nil {
            Text("Read").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.57))
        } else if message.block(.delivered, at: time) != nil {
            Text("Delivered").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.57))
        }
    }

    private var bubbleContent: some View {
        Group {
            if hasCue, let motif = message.motif, let name = motif.placeName {
                placeAttachment(motif, name: name)
                    .transition(reduceMotion ? .identity : .opacity)
            } else if message.twitterLinkStart != nil {
                VStack(alignment: message.right ? .trailing : .leading, spacing: 4) {
                    if hasTwitterLink {
                        let otherContent = compact ? (current ? 98.0 : 132.0) : 137.0
                        let side = min(maxWidth, compact ? 178 : 236, max(101, viewportHeight - otherContent))
                        StudioTwitterCard(side: side)
                            .padding(message.right ? .trailing : .leading, 4)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                    speechBubble.accessibilityHidden(hasTwitterLink)
                }
            } else {
                speechBubble
            }
        }
        .modifier(SceneLyricPerformance(message: message, time: time, current: current, reduceMotion: reduceMotion, compact: compact))
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: hasCue)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: hasTwitterLink)
    }

    private func placeAttachment(_ motif: StudioLyricScore.Motif, name: String) -> some View {
        let width = min(maxWidth, compact ? 278 : 342)
        let outline = RoundedRectangle(cornerRadius: compact ? 15 : 19, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            ScenePlaceChart(place: motif, elapsed: reduceMotion ? 1 : time - message.motifStart)
                .frame(width: width, height: width / (compact ? 3.1 : 2.7))
                .clipped()

            VStack(alignment: .leading, spacing: compact ? 7 : 11) {
                // Reserve the finished lyric's height so the map and caption stay still as words wrap.
                Text(verbatim: message.text)
                    .font(.system(size: fontSize, weight: .medium))
                    .hidden()
                    .overlay(alignment: .topLeading) { lyricWords }
                    .tracking(-0.32)
                    .lineLimit(current ? (compact ? 5 : 8) : 2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.system(size: compact ? 9 : 11, weight: .semibold))
                    Text(verbatim: name)
                        .font(.system(size: min(15, max(11, fontSize * 0.67)), weight: .medium))
                }
                .foregroundStyle(Color(white: 0.69))
                .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 15)
            .padding(.top, compact ? 7 : 10)
            .padding(.bottom, compact ? 9 : 12)
            .accessibilityHidden(true)
        }
        .frame(width: width)
        .background(Color(white: 0.135))
        .clipShape(outline)
        .overlay { outline.strokeBorder(.white.opacity(0.075), lineWidth: 0.5).allowsHitTesting(false) }
    }

    private var speechBubble: some View {
        let effect = current && !reduceMotion ? message.bubbleEffect(at: time) : nil
        let ink = effect.flatMap { $0.kind == .invisibleInk ? max(0, 1 - (time - $0.start) / 0.78) : nil } ?? 0
        return SceneLyricWidth(maxWidth: maxWidth) {
            VStack(alignment: .leading, spacing: 5) {
                lyricWords
                    .blur(radius: ink * 3)
                    .opacity(1 - 0.63 * ink)
                if message.repeated, current {
                    SceneBeatTrace(words: message.words, time: time, reduceMotion: reduceMotion, tint: palette.highlight)
                        .frame(width: CGFloat(message.words.count) * 16 + 8, height: 14)
                }
            }
            .tracking(-0.32)
            .foregroundStyle(.white)
            .lineLimit(current ? (compact ? 7 : 10) : 2)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, compact ? 13 : 17)
            .padding(.vertical, compact ? 8 : 11)
            .padding(message.right ? .trailing : .leading, 3)
        }
        .background {
            ZStack {
                shape.fill(fill)
                if let motif = message.motif, current && hasCue && [.ashes, .rain, .stars].contains(motif) {
                    SceneWordAtmosphere(motif: motif, elapsed: reduceMotion ? 0.5 : max(0, time - message.motifStart),
                                        tint: palette.highlight)
                }
            }
        }
        .clipShape(shape)
        .overlay(alignment: message.right ? .topLeading : .topTrailing) {
            if showsHeart {
                SceneMessageTapback(mark: .heart, outgoingMessage: message.right)
                    .scaleEffect(reduceMotion ? 1 : 1 - 0.32 * exp(-12 * max(0, time - message.motifStart)),
                                 anchor: .bottom)
                    .offset(x: message.right ? -12 : 12, y: -21)
            }
        }
        .padding(.top, showsHeart ? 20 : 0)
    }

    @ViewBuilder private var lyricWords: some View {
        if current {
            arrivingWords.font(.system(size: fontSize, weight: .medium))
                .textRenderer(SceneWordRenderer(position: time, reduceMotion: reduceMotion,
                                                tint: palette.highlight.mix(with: .white, by: message.right ? 0.56 : 0.27),
                                                performanceAccent: performanceAccent))
        } else if message.decorations.contains(where: { $0.effect.target == .formatting }) {
            arrivingWords.font(.system(size: fontSize, weight: .medium))
        } else if count == message.words.count {
            styledLyric(message.text).font(.system(size: fontSize, weight: .medium))
        } else {
            styledLyric(message.words.prefix(count).map(\.text).joined().trimmingCharacters(in: .whitespaces))
                .font(.system(size: fontSize, weight: .medium))
        }
    }

    private var arrivingWords: Text {
        guard count > 0 else { return Text(verbatim: "…").foregroundStyle(.white.opacity(0.55)) }
        var text = Text(verbatim: "")
        // A word-timed source may split "Twit" and "ter.com" into separate sung runs.
        let domain = hasTwitterLink ? (message.words.map(\.text).joined() as NSString).range(of: "Twitter.com") : nil
        var offset = 0
        for (index, word) in message.words.prefix(count).enumerated() {
            let content = index == count - 1 ? String(word.text.trimmingSuffixSpaces) : word.text
            let blocks = message.textBlocks(for: index, at: time)
            let formats = Set(blocks.map(\.effect))
            var styled = styledLyric(content, offset: offset, domain: domain)
            if formats.contains(.bold) { styled = styled.bold() }
            if formats.contains(.italic) { styled = styled.italic() }
            if formats.contains(.underline) { styled = styled.underline() }
            if formats.contains(.strikethrough) { styled = styled.strikethrough() }
            let motion = blocks.last {
                $0.effect.target == .text && time - max(word.start, message.cueStart + $0.delay) < 0.78
            }
            text = text + styled.customAttribute(SceneWordArrival(
                start: word.start, accent: message.accents[index],
                customAccent: motion?.effect.wordAccent,
                customStart: motion.map { max(word.start, message.cueStart + $0.delay) }
            ))
            if domain != nil { offset += word.text.utf16.count }
        }
        return text
    }

    private func styledLyric(_ content: String, offset: Int = 0, domain: NSRange? = nil) -> Text {
        guard hasTwitterLink else { return Text(verbatim: content) }
        let target = domain ?? (content as NSString).range(of: "Twitter.com")
        guard target.location != NSNotFound else { return Text(verbatim: content) }
        let overlap = NSIntersectionRange(target, NSRange(location: offset, length: content.utf16.count))
        guard overlap.length > 0,
              let range = Range(NSRange(location: overlap.location - offset, length: overlap.length), in: content) else {
            return Text(verbatim: content)
        }
        var link = AttributedString(String(content[range]))
        link.link = StudioTwitterCard.destination
        link.underlineStyle = .single
        link.foregroundColor = message.right ? .white : Color(red: 0.26, green: 0.64, blue: 1)
        return Text(AttributedString(String(content[..<range.lowerBound])) + link + AttributedString(String(content[range.upperBound...])))
    }
}

private extension String {
    var trimmingSuffixSpaces: Substring {
        var slice = self[...]
        while slice.last?.isWhitespace == true { slice.removeLast() }
        return slice
    }
}

/// Short lyric bubbles hug their words. Longer ones wrap at the conversation margin.
private struct SceneLyricWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, maxWidth)
        return child.sizeThatFits(.init(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: bounds.height))
    }
}

nonisolated private struct SceneBubbleShape: Shape {
    let right: Bool
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        let radius = min(19, height * 0.48)
        let inset = 4.0
        let body = CGRect(x: inset, y: 0, width: max(0, width - inset), height: height)
        var path = Path(roundedRect: body, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        if tail {
            // One contour gives both clipping and fill the same swept corner.
            let r = min(radius, body.width / 2)
            let k = r * 0.55
            path = Path()
            path.move(to: .init(x: inset + r, y: 0))
            path.addLine(to: .init(x: width - r, y: 0))
            path.addCurve(to: .init(x: width, y: r),
                          control1: .init(x: width - r + k, y: 0), control2: .init(x: width, y: r - k))
            path.addLine(to: .init(x: width, y: height - r))
            path.addCurve(to: .init(x: width - r, y: height),
                          control1: .init(x: width, y: height - r + k), control2: .init(x: width - r + k, y: height))
            path.addLine(to: .init(x: inset + r, y: height))
            path.addQuadCurve(to: .init(x: inset + 6, y: height - 2), control: .init(x: inset + 9, y: height))
            path.addQuadCurve(to: .init(x: 0, y: height), control: .init(x: inset + 2, y: height + 0.5))
            path.addQuadCurve(to: .init(x: inset, y: height - 14), control: .init(x: inset + 1, y: height - 4))
            path.addLine(to: .init(x: inset, y: r))
            path.addCurve(to: .init(x: inset + r, y: 0),
                          control1: .init(x: inset, y: r - k), control2: .init(x: inset + r - k, y: 0))
            path.closeSubpath()
        }
        if right { path = path.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)) }
        return path.applying(.init(translationX: rect.minX, y: rect.minY))
    }
}

private struct SceneBeatTrace: View {
    let words: [StudioWord]
    let time: Double
    let reduceMotion: Bool
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let step = (size.width - 12) / CGFloat(max(1, words.count - 1))
            let baseline = size.height / 2
            var track = Path()
            track.move(to: CGPoint(x: 6, y: baseline))
            track.addLine(to: CGPoint(x: size.width - 6, y: baseline))
            context.stroke(track, with: .color(.white.opacity(0.25)), lineWidth: 1)
            for (index, word) in words.enumerated() {
                let x = 6 + CGFloat(index) * step
                let age = time - word.start
                let pulse = reduceMotion || age < 0 ? 0 : max(0, 1 - age / 0.32)
                let node = CGRect(x: x - 2.5, y: baseline - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: node), with: .color(age >= 0 ? tint : .white.opacity(0.36)))
                if pulse > 0 {
                    context.stroke(Path(ellipseIn: node.insetBy(dx: -4 * (1 - pulse), dy: -4 * (1 - pulse))),
                                   with: .color(tint.opacity(pulse)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
