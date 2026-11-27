import ImageIO
import SwiftUI

/// A lifted sticker carries its shadow. On release the edge flattens against
/// the message; only the small contact shadow remains in conversation history.
struct SceneSlowSilverSticker: View {
    let age: Double
    let messageRight: Bool
    let compact: Bool
    let reduceMotion: Bool

    private static let decal: CGImage? = {
        guard let url = Bundle.module.url(forResource: "slow-silver-03", withExtension: "png", subdirectory: "StudioStickers"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let surface = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let keyline = bounds.width * 0.026
        surface.setFillColor(CGColor(gray: 0.97, alpha: 1))
        for i in 0..<16 {
            let a = Double(i) * .pi / 8
            surface.saveGState()
            surface.clip(to: bounds.offsetBy(dx: keyline * cos(a), dy: keyline * sin(a)), mask: original)
            surface.fill(bounds)
            surface.restoreGState()
        }
        surface.draw(original, in: bounds)
        return surface.makeImage()
    }()

    var body: some View {
        let pose = StudioStickerPlacement.sample(age: age, messageRight: messageRight,
                                                   compact: compact, reduceMotion: reduceMotion)
        let contact: UnitPoint = messageRight ? .bottomTrailing : .bottomLeading
        Canvas { context, size in
            guard let decal = Self.decal else { return }
            let art = Image(decorative: decal, scale: 1)
            let face = context.resolve(art.interpolation(.high))
            let bounds = CGRect(origin: .zero, size: size)
            let lift = min(1, abs(pose.pitchDegrees) / 32)
            guard lift > 0.018 || pose.glintAlpha > 0.005 else {
                context.draw(face, in: bounds)
                return
            }
            // Bend the free wing slightly toward the corner already touching the bubble.
            // The light is clipped to the decal's alpha, including the feather gaps.
            var sheen = context.resolve(art.renderingMode(.template))
            let lightX = bounds.width * (messageRight ? lift : 1 - lift)
            sheen.shading = .linearGradient(Gradient(colors: [.clear, .white.opacity(pose.glintAlpha), .clear]),
                                           startPoint: .init(x: lightX - 10, y: 0),
                                           endPoint: .init(x: lightX + 13, y: bounds.height * 0.38))
            let bandCount = 14
            for row in 0..<bandCount {
                let y = Double(row) / Double(bandCount)
                let bend = pow(1 - y, 2.0) * lift
                let dx = bounds.width * bend * 0.076
                let projected = CGRect(x: messageRight ? dx : 0, y: 0,
                                       width: bounds.width - dx, height: bounds.height)
                var strip = context
                let region = CGRect(x: 0, y: y * bounds.height, width: bounds.width, height: bounds.height / Double(bandCount))
                strip.clip(to: Path(region), style: .init(antialiased: false))
                strip.draw(face, in: projected)
                if pose.glintAlpha > 0.005 { strip.draw(sheen, in: projected) }
            }
        }
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: contact)
        .rotation3DEffect(.degrees(pose.pitchDegrees), axis: (x: 0, y: 1, z: 0), anchor: contact, perspective: 0.45)
        .rotationEffect(.degrees(pose.rotationDegrees))
        .shadow(color: .black.opacity(pose.shadowOpacity), radius: pose.shadowRadius, y: pose.shadowY)
        .offset(x: pose.dx, y: pose.dy)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
