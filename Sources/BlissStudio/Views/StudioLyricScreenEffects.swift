import SwiftUI

extension StudioEffectsGraph.Tint {
    var lightColor: Color {
        switch self {
        case .gold: Color(red: 1, green: 0.76, blue: 0.36)
        case .coral: Color(red: 1, green: 0.46, blue: 0.46)
        case .mint: Color(red: 0.46, green: 0.95, blue: 0.76)
        case .violet: Color(red: 0.73, green: 0.56, blue: 1)
        case .blue: Color(red: 0.42, green: 0.68, blue: 1)
        }
    }

    var bubbleColor: Color {
        switch self {
        case .gold: Color(red: 0.45, green: 0.28, blue: 0.08)
        case .coral: Color(red: 0.49, green: 0.16, blue: 0.23)
        case .mint: Color(red: 0.08, green: 0.35, blue: 0.31)
        case .violet: Color(red: 0.30, green: 0.17, blue: 0.50)
        case .blue: Color(red: 0.13, green: 0.25, blue: 0.53)
        }
    }
}

struct SceneLyricScreenEffects: View {
    let message: StudioLyricScore.Message
    let time: Double

    var body: some View {
        let effects = message.decorations.compactMap { block -> (StudioEffectsGraph.Block, Double)? in
            let age = time - message.cueStart - block.delay
            return block.effect.target == .screen && age >= 0 && age < 1.5 ? (block, age) : nil
        }
        if !effects.isEmpty {
            Canvas { context, size in
                for (block, age) in effects {
                    let center = CGPoint(x: size.width * (message.right ? 0.64 : 0.36), y: size.height * 0.5)
                    let p = age / 1.5
                    let tint = block.tint.lightColor
                    switch block.effect {
                    case .sparks: sparks(in: context, at: center, size: size, progress: p, tint: tint)
                    case .ripple: ripples(in: context, at: center, size: size, progress: p, tint: tint)
                    case .rain: rain(in: context, size: size, progress: p, tint: tint)
                    case .spotlight: spotlight(in: context, size: size, at: center, progress: p, tint: tint)
                    case .balloons, .love: floatShapes(in: context, size: size, progress: p, tint: tint, hearts: block.effect == .love)
                    case .confetti, .celebration: confetti(in: context, size: size, progress: p, tint: tint, metallic: block.effect == .celebration)
                    case .lasers: lasers(in: context, size: size, progress: p, tint: tint)
                    case .fireworks: fireworks(in: context, size: size, progress: p, tint: tint)
                    case .shootingStar: shootingStar(in: context, size: size, progress: p, tint: tint)
                    default: break
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func sparks(in context: GraphicsContext, at center: CGPoint, size: CGSize, progress p: Double, tint: Color) {
        let spread = min(size.width, size.height) * 0.92
        let travel = 1 - pow(1 - p, 2)
        for index in 0..<36 {
            let i = Double(index)
            let theta = i * 2.39996
            let radius = spread * travel * (0.38 + 0.62 * unit(i * 0.3721))
            let x = center.x + cos(theta) * radius * 1.6
            let y = center.y + sin(theta) * radius + p * p * 26
            let length = 1.5 + 5 * unit(i * 0.552)
            let opacity = pow(1 - p, 1.3) * min(1, p * 25)
            let tail = CGPoint(x: x - cos(theta) * length * 2.6, y: y - sin(theta) * length * 2.6)
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: CGPoint(x: x, y: y))
            context.stroke(streak, with: .linearGradient(
                Gradient(colors: [tint.opacity(0), tint.opacity(opacity)]),
                startPoint: tail, endPoint: CGPoint(x: x, y: y)),
                style: StrokeStyle(lineWidth: max(1, length * 0.38), lineCap: .round))
            if index.isMultiple(of: 4) {
                context.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)),
                             with: .color(.white.opacity(opacity * 0.86)))
            }
        }
    }

    private func ripples(in context: GraphicsContext, at center: CGPoint, size: CGSize, progress p: Double, tint: Color) {
        let limit = min(size.width, size.height) * 1.18
        for index in 0..<3 {
            let wave = p * 1.22 - Double(index) * 0.16
            guard wave > 0 && wave < 1 else { continue }
            let radius = 18 + limit * (1 - pow(1 - wave, 2))
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let alpha = sin(.pi * wave) * (0.72 - Double(index) * 0.13)
            context.stroke(Path(ellipseIn: rect), with: .linearGradient(
                Gradient(colors: [tint.opacity(alpha), tint.opacity(alpha * 0.26)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)),
                style: StrokeStyle(lineWidth: 1 + (1 - wave) * 2, dash: index == 2 ? [2, 7] : []))
        }
    }

    private func rain(in context: GraphicsContext, size: CGSize, progress p: Double, tint: Color) {
        let envelope = min(1, p * 9) * pow(1 - p, 0.8)
        for index in 0..<44 {
            let i = Double(index + 1)
            let speed = 0.55 + unit(i * 0.57)
            let y = unit(i * 0.618 + p * speed) * (size.height + 40) - 20
            let x = unit(i * 0.423) * (size.width + 40) - y * 0.11
            let start = CGPoint(x: x + 4, y: y - 24 * speed)
            let end = CGPoint(x: x, y: y)
            var drop = Path()
            drop.move(to: start)
            drop.addLine(to: end)
            context.stroke(drop, with: .linearGradient(
                Gradient(colors: [.clear, tint.opacity(envelope * speed * 0.57)]),
                startPoint: start, endPoint: end), lineWidth: speed)
        }
    }

    private func spotlight(in context: GraphicsContext, size: CGSize, at center: CGPoint, progress p: Double, tint: Color) {
        let sweep = (p - 0.52) * size.width * 0.46
        let light = CGPoint(x: center.x + sweep, y: center.y)
        let bounds = Path(CGRect(origin: .zero, size: size))
        let glow = sin(.pi * p)
        context.fill(bounds, with: .radialGradient(
            Gradient(colors: [tint.opacity(glow * 0.33), tint.opacity(glow * 0.14), .clear]),
            center: light, startRadius: 4, endRadius: min(size.width, size.height) * 0.67))
    }

    private func floatShapes(in context: GraphicsContext, size: CGSize, progress p: Double, tint: Color, hearts: Bool) {
        let symbol = hearts ? "heart.fill" : "balloon.fill"
        for i in 0..<(hearts ? 11 : 14) {
            let seed = Double(i + 1)
            let width = min(size.width, size.height) * (0.052 + 0.105 * unit(seed * 0.65))
            let color = tint.mix(with: i.isMultiple(of: 3) ? .pink : .white, by: unit(seed * 0.39) * 0.43)
            let rise = p * (1.07 + unit(seed * 0.52) * 0.35)
            let position = CGPoint(x: size.width * unit(seed * 0.618) + sin(p * 6 + seed) * width * 0.23,
                                   y: size.height * (1.13 - rise) + 5 * seed)
            var layer = context
            layer.opacity = sin(.pi * p) * 0.82
            layer.draw(Text(Image(systemName: symbol)).font(.system(size: width)).foregroundStyle(color), at: position)
            if !hearts {
                var string = Path()
                string.move(to: CGPoint(x: position.x, y: position.y + width * 0.35))
                string.addQuadCurve(to: CGPoint(x: position.x + width * 0.27, y: position.y + width * 1.1),
                                    control: CGPoint(x: position.x - width * 0.21, y: position.y + width * 0.82))
                layer.stroke(string, with: .color(color.opacity(0.53)), lineWidth: 1)
            }
        }
    }

    private func confetti(in context: GraphicsContext, size: CGSize, progress p: Double, tint: Color, metallic: Bool) {
        let colors: [Color] = [tint, .white, .cyan, .pink, .yellow]
        for i in 0..<64 {
            let seed = Double(i + 1)
            let x = size.width * unit(seed * 0.618) + sin(seed + 8 * p) * 12
            let y = size.height * (p * (0.75 + 0.52 * unit(seed * 0.43)) - unit(seed * 0.795) * 0.42)
            let width = 2 + unit(seed * 0.56) * 6
            var layer = context
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .radians(seed + p * (5 + unit(seed * 0.43) * 10)))
            layer.opacity = min(1, p * 12) * pow(1 - p, 0.63) * (metallic ? 0.55 + 0.45 * sin(seed + p * 23) : 0.88)
            let rect = CGRect(x: -width / 2, y: -width * 0.74, width: width, height: width * 1.48)
            layer.fill(Path(roundedRect: rect, cornerRadius: metallic ? width / 2 : 1), with: .color(
                metallic ? tint.mix(with: .white, by: unit(seed * 0.64) * 0.65) : colors[i % colors.count]))
        }
    }

    private func lasers(in context: GraphicsContext, size: CGSize, progress p: Double, tint: Color) {
        let colors: [Color] = [tint, .purple, .cyan, .mint]
        for i in 0..<8 {
            let seed = Double(i)
            let from = CGPoint(x: i.isMultiple(of: 2) ? 0 : size.width, y: size.height * (0.7 - 0.35 * unit(seed * 0.73)))
            let to = CGPoint(x: size.width - from.x, y: size.height * (0.3 + 0.34 * sin(seed * 2.07 + p * 4.8)))
            let color = colors[i % colors.count]
            let opacity = sin(.pi * p) * 0.73
            var beam = Path()
            beam.move(to: from)
            beam.addLine(to: to)
            context.stroke(beam, with: .color(color.opacity(opacity * 0.13)), lineWidth: 9)
            context.stroke(beam, with: .linearGradient(
                Gradient(colors: [color.opacity(opacity), .clear]), startPoint: from, endPoint: to),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }

    private func fireworks(in context: GraphicsContext, size: CGSize, progress p: Double, tint: Color) {
        let centers: [CGPoint] = [
            .init(x: size.width * 0.31, y: size.height * 0.39),
            .init(x: size.width * 0.72, y: size.height * 0.42),
            .init(x: size.width * 0.53, y: size.height * 0.22)
        ]
        for (i, center) in centers.enumerated() {
            let bloom = (p - Double(i) * 0.16) / 0.67
            guard bloom > 0 && bloom < 1 else { continue }
            var layer = context
            layer.opacity = i == 0 ? 0.96 : 0.79
            sparks(in: layer, at: center, size: CGSize(width: size.width * 0.43, height: size.height * 0.60),
                   progress: bloom, tint: tint.mix(with: i == 1 ? .pink : .white, by: Double(i) * 0.22))
        }
    }

    private func shootingStar(in context: GraphicsContext, size: CGSize, progress p: Double, tint: Color) {
        let alpha = sin(.pi * p)
        let head = CGPoint(x: size.width * (0.09 + p * 0.80), y: size.height * (0.20 + p * 0.25))
        let tail = CGPoint(x: head.x - size.width * 0.28, y: head.y - size.height * 0.087)
        var trail = Path()
        trail.move(to: tail)
        trail.addQuadCurve(to: head, control: CGPoint(x: head.x - size.width * 0.13, y: head.y - size.height * 0.06))
        context.stroke(trail, with: .linearGradient(
            Gradient(colors: [.clear, tint.opacity(0.93 * alpha)]), startPoint: tail, endPoint: head), lineWidth: 3)
        context.draw(Text(Image(systemName: "star.fill")).font(.system(size: 17)).foregroundStyle(tint.opacity(alpha)), at: head)
    }

    private func unit(_ value: Double) -> Double { value - floor(value) }
}
