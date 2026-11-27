import SwiftUI

struct SceneWordArrival: TextAttribute {
    let start: Double
    let accent: StudioWordAccent?
    var customAccent: StudioWordAccent? = nil
    var customStart: Double? = nil
}

/// Draw over the system-shaped glyphs. Moving a word changes its ink, so the
/// surrounding text and bubble keep the same measurements throughout its accent.
struct SceneWordRenderer: TextRenderer {
    let position: Double
    let reduceMotion: Bool
    let tint: Color
    var performanceAccent: Double = 0

    var displayPadding: EdgeInsets { .init(top: 8, leading: 5, bottom: 6, trailing: 5) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let arrival = run[SceneWordArrival.self] else {
                    context.draw(run)
                    continue
                }
                let age = position - arrival.start
                var layer = context
                let customAge = position - (arrival.customStart ?? arrival.start)
                if let accent = arrival.customAccent, customAge >= 0, customAge < accent.duration {
                    if reduceMotion {
                        context.draw(run)
                    } else {
                        draw(accent, age: customAge, run: run, in: layer)
                    }
                } else if let accent = arrival.accent, age >= 0, age < accent.duration {
                    if reduceMotion {
                        layer.addFilter(.colorMultiply(tint))
                        layer.draw(run)
                    } else {
                        draw(accent, age: age, run: run, in: layer)
                    }
                } else {
                    if !reduceMotion, age >= 0, age < 0.18 {
                        let settle = pow(1 - age / 0.18, 3)
                        layer.opacity *= 1 - settle * 0.52
                        layer.translateBy(x: 0, y: settle * 3)
                    }
                    layer.draw(run)
                }
            }
        }
    }

    private func draw(_ accent: StudioWordAccent, age: Double, run: Text.Layout.Run, in context: GraphicsContext) {
        let phase = age / accent.duration
        let attack = min(1, age / min(0.09, accent.duration * 0.22))
        let release = min(1, (accent.duration - age) / min(0.21, accent.duration * 0.38))
        let amount = attack * release * accent.strength * (1 + 0.18 * performanceAccent)
        let bounds = run.typographicBounds.rect
        let em = bounds.height
        var layer = context
        layer.addFilter(.colorMultiply(tint.mix(with: .white, by: max(0, 1 - 0.86 * amount))))

        switch accent.kind {
        case .big:
            let lift = amount * (1 - 0.18 * phase)
            let horizontal = min(0.25, em * 0.22 / max(1, bounds.width))
            transform(&layer, at: bounds, dx: 0, dy: -em * 0.09 * lift,
                      sx: 1 + horizontal * lift, sy: 1 + 0.34 * lift)
        case .small:
            transform(&layer, at: bounds, dx: 0, dy: em * 0.07 * amount,
                      sx: 1 - 0.19 * amount, sy: 1 - 0.27 * amount)
        case .shake:
            let swing = sin(2 * .pi * min(2.1, accent.duration * 6.2) * phase) * amount
            transform(&layer, at: bounds, dx: em * 0.16 * swing, dy: 0, angle: .degrees(3 * swing))
        case .nod:
            let firstDip = sin(2 * .pi * phase) * amount
            transform(&layer, at: bounds, dx: 0, dy: em * 0.17 * firstDip, sy: 1 - 0.20 * firstDip,
                      angle: .degrees(3.5 * firstDip))
        case .ripple, .bloom, .explode, .jitter:
            if accent.kind == .bloom {
                layer.addFilter(.shadow(color: tint.opacity(0.52 * amount), radius: 2.4 * amount))
            }
            drawLetters(in: run, accent: accent, phase: phase, amount: amount, context: layer)
            return
        }
        layer.draw(run)
    }

    private func drawLetters(in run: Text.Layout.Run, accent: StudioWordAccent, phase: Double,
                             amount: Double, context: GraphicsContext) {
        let count = Double(max(1, run.count - 1))
        let em = run.typographicBounds.rect.height
        for (index, glyph) in run.enumerated() {
            var layer = context
            let fraction = Double(index) / count
            let rect = glyph.typographicBounds.rect
            switch accent.kind {
            case .ripple:
                let cycles = min(2, 0.8 + accent.duration * 0.55)
                let wave = sin(2 * .pi * (phase * cycles - fraction * 0.82)) * amount
                transform(&layer, at: rect, dx: 0, dy: -em * 0.22 * wave, angle: .degrees(4 * wave))
            case .bloom:
                // Open the petals from the middle of the word and let the long
                // vowel linger. Every letter returns to its shaped baseline.
                let distance = abs(fraction * 2 - 1)
                let opening = min(1, max(0, (phase - 0.18 * distance) / 0.34))
                let lift = amount * sin(.pi * 0.5 * opening) * (1 - 0.32 * distance)
                transform(&layer, at: rect, dx: 0, dy: -em * 0.16 * lift,
                          sx: 1 + 0.08 * lift, sy: 1 + 0.24 * lift)
            case .explode:
                let spread = (1 - pow(phase, 0.65)) * amount
                let direction = run.count == 1 ? 0 : fraction * 2 - 1
                let angle = sin(Double(index) * 2.4 + 0.7)
                transform(&layer, at: rect, dx: em * 0.25 * direction * spread,
                          dy: -em * (0.15 + 0.20 * angle) * spread,
                          sy: 1 + 0.16 * spread, angle: .degrees(19 * angle * spread))
            case .jitter:
                let tick = phase * min(5, accent.duration * 8) * 2 * .pi
                let seed = Double(index) * 2.39996
                let dx = sin(tick + seed) * amount
                let dy = sin(tick * 1.47 - seed) * amount
                transform(&layer, at: rect, dx: em * 0.057 * dx, dy: em * 0.085 * dy, angle: .degrees(6 * dx))
            default: break
            }
            layer.draw(glyph)
        }
    }

    private func transform(_ layer: inout GraphicsContext, at rect: CGRect, dx: CGFloat, dy: CGFloat,
                           sx: CGFloat = 1, sy: CGFloat = 1, angle: Angle = .zero) {
        layer.translateBy(x: rect.midX + dx, y: rect.midY + dy)
        layer.rotate(by: angle)
        layer.scaleBy(x: sx, y: sy)
        layer.translateBy(x: -rect.midX, y: -rect.midY)
    }
}
