import AppKit
import SwiftUI

/// The sampled colors are shared by the frame, the light behind the sleeve, and the lyric cards.
struct StudioPalette {
    let primary: Color
    let secondary: Color
    let highlight: Color

    static let dusk = StudioPalette(
        primary: Color(red: 0.98, green: 0.35, blue: 0.22),
        secondary: Color(red: 0.56, green: 0.30, blue: 0.94),
        highlight: Color(red: 1, green: 0.78, blue: 0.55)
    )

    static func from(_ image: NSImage?) -> Self {
        guard let image, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .dusk }
        let side = 28
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let ctx = CGContext(
                data: storage.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .dusk }

        var bins = [Double](repeating: 0, count: 24)
        var totalSaturation = 0.0
        var visiblePixels = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 200 {
            let color = NSColor(srgbRed: CGFloat(bytes[i]) / 255, green: CGFloat(bytes[i + 1]) / 255,
                                blue: CGFloat(bytes[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            if v < 0.09 { continue }
            visiblePixels += 1
            totalSaturation += s
            let index = Int((h * 24).rounded()) % 24
            bins[index] += s * s * v
        }
        let saturation = totalSaturation / Double(max(1, visiblePixels))
        guard saturation > 0.075, let first = bins.indices.max(by: { bins[$0] < bins[$1] }) else {
            return Self(primary: .gray, secondary: Color(white: 0.52), highlight: Color(white: 0.9))
        }
        let chroma = min(0.91, max(0.32, saturation * 1.4))
        let alternatives = bins.indices.filter {
            let distance = abs($0 - first)
            return min(distance, 24 - distance) >= 3
        }
        let candidate = alternatives.max { bins[$0] < bins[$1] } ?? first
        let second = bins[candidate] > bins[first] * 0.08 ? candidate : (first + 2) % 24
        return Self(
            primary: Color(hue: Double(first) / 24, saturation: chroma, brightness: 0.95),
            secondary: Color(hue: Double(second) / 24, saturation: chroma * 0.88, brightness: 0.87),
            highlight: Color(hue: Double(first) / 24, saturation: chroma * 0.38, brightness: 1)
        )
    }
}

struct StudioCover: View {
    let artwork: NSImage?
    let isPreview: Bool

    var body: some View {
        GeometryReader { geo in
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            } else if isPreview {
                NightFerrySleeve()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.17), Color(white: 0.065)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: min(geo.size.width, geo.size.height) * 0.27, weight: .thin))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One persistent sleeve changes its bounds, so a reversed gesture starts from the visible crop.
struct StudioArtworkStage: View {
    let artwork: NSImage?
    let enhancedArtwork: NSImage?
    let isPreview: Bool
    let palette: StudioPalette
    let resting: CGRect
    let size: CGSize
    let expanded: Bool
    let setExpanded: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let rect = expanded ? CGRect(origin: .zero, size: size) : resting
        let radius = expanded ? 0 : resting.width * 0.048
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let action = expanded ? "Collapse artwork" : "Expand artwork"
        ZStack(alignment: .topLeading) {
            // The pool stays behind for a moment as the sleeve opens into the scene.
            ZStack {
                RadialGradient(colors: [palette.secondary.opacity(0.43), palette.primary.opacity(0.18), .clear],
                               center: .center, startRadius: resting.width * 0.13, endRadius: resting.width * 0.82)
                if let artwork {
                    Image(nsImage: artwork).resizable().interpolation(.low).scaledToFill()
                        .frame(width: resting.width, height: resting.height)
                        .clipped().blur(radius: max(15, resting.width * 0.16)).opacity(0.51)
                }
            }
            .frame(width: resting.width * 1.85, height: resting.height * 1.85)
            .position(x: resting.midX, y: resting.midY + resting.height * 0.10)
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(false).accessibilityHidden(true)

            Button { setExpanded(!expanded) } label: {
                StudioCover(artwork: artwork, isPreview: isPreview)
                    .overlay {
                        if let enhancedArtwork {
                            StudioCover(artwork: enhancedArtwork, isPreview: false).transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: enhancedArtwork != nil)
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.75), location: 0), .init(color: .black.opacity(0.46), location: 0.10),
                            .init(color: .clear, location: 0.27), .init(color: .clear, location: 0.52),
                            .init(color: .black.opacity(0.68), location: 0.81), .init(color: .black.opacity(0.88), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                        .opacity(expanded ? 1 : 0)
                    }
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(.white.opacity(expanded ? 0 : 0.21), lineWidth: 0.75) }
                    .overlay(alignment: .bottomTrailing) {
                        if hovered && !expanded {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(.black.opacity(0.50), in: Circle())
                                .padding(8).transition(.opacity)
                        }
                    }
                    .shadow(color: .black.opacity(expanded ? 0 : 0.40), radius: resting.width * 0.045, y: 5)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(action)
            .help(action + " (A)")
            .onHover { isOver in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovered = isOver }
            }
            .simultaneousGesture(MagnifyGesture().onEnded { gesture in
                if gesture.magnification > 1.12 { setExpanded(true) }
                if gesture.magnification < 0.89 { setExpanded(false) }
            })
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Original print-style sleeve for the built-in session. All coordinates are in a 500-point artboard.
private struct NightFerrySleeve: View {
    var body: some View {
        Canvas { context, size in
            let side = max(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 500, y: side / 500)
            let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
            let sky = Gradient(colors: [Self.color(0x59344F), Self.color(0xD6544A), Self.color(0xFF9464), Self.color(0xF6B87F)])
            context.fill(Path(bounds), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 48, y: 356)))
            let sun = CGRect(x: 286, y: 75, width: 128, height: 128)
            context.fill(Path(ellipseIn: sun), with: .linearGradient(
                Gradient(colors: [Self.color(0xFFF0B5), Self.color(0xFFBF84)]),
                startPoint: CGPoint(x: 345, y: 75), endPoint: CGPoint(x: 345, y: 203)
            ))

            // Distant coast. Its muted warm layers give the cool foreground water depth.
            land(&context, color: 0xB96162, points: [(0,232),(55,225),(83,217),(119,222),(160,205),(181,208),(204,202),(238,215),(290,211),(342,189),(365,185),(390,189),(443,181),(500,168)])
            land(&context, color: 0x855268, points: [(0,248),(47,238),(81,238),(135,231),(184,238),(232,233),(280,223),(351,220),(406,204),(445,210),(500,198)])
            land(&context, color: 0x59485E, points: [(0,263),(61,258),(114,253),(170,255),(218,251),(282,248),(320,242),(351,244),(431,236),(470,224),(500,224)])
            context.fill(Path(CGRect(x: 0, y: 263, width: 500, height: 237)), with: .linearGradient(
                Gradient(colors: [Self.color(0xB98288), Self.color(0x726182), Self.color(0x36394F)]),
                startPoint: CGPoint(x: 250, y: 263), endPoint: CGPoint(x: 175, y: 505)
            ))

            // Broken waves and sun glitter are deterministic, so the paper artwork never shimmers.
            var noise = PaperNoise()
            for band in 0..<73 {
                let depth = Double(band) / 72
                let y = 264 + depth * depth * 237
                let reflected = 340 + 7 * sin(Double(band) * 0.57) - 92 * depth
                for _ in 0..<13 {
                    let x = noise.unit * 550 - 25
                    let length = (2 + 52 * noise.unit) * (0.32 + depth)
                    let lit = abs(x - reflected) < (16 + depth * 48) * (0.48 + noise.unit)
                    let color = lit ? Self.color(0xFFC19D) : (noise.unit > 0.58 ? Self.color(0xDEC0B2) : Self.color(0x322E49))
                    var wave = Path()
                    wave.move(to: CGPoint(x: x, y: y))
                    wave.addQuadCurve(to: CGPoint(x: x + length, y: y + 0.25),
                                      control: CGPoint(x: x + length * 0.42, y: y - depth))
                    context.stroke(wave, with: .color(color.opacity(lit ? 0.80 : 0.15 + depth * 0.10)),
                                   lineWidth: 0.45 + depth * 0.95)
                }
            }
            drawFerry(&context)

            let lettering = Self.color(0xFFE0BB)
            context.draw(Text("AFTER HOURS").font(.system(size: 26, weight: .medium, design: .serif)).tracking(1)
                .foregroundStyle(lettering), at: CGPoint(x: 25, y: 24), anchor: .topLeading)
            context.draw(Text("G R A F T   S E S S I O N S").font(.system(size: 6.7, weight: .semibold))
                .foregroundStyle(lettering.opacity(0.86)), at: CGPoint(x: 27, y: 61), anchor: .topLeading)
            for _ in 0..<1_100 {
                let x = noise.unit * 500, y = noise.unit * 500
                context.fill(Path(CGRect(x: x, y: y, width: 0.75, height: 0.8)),
                             with: .color(.white.opacity(noise.unit * 0.18)))
            }
        }
        .drawingGroup(opaque: true)
    }

    private func land(_ context: inout GraphicsContext, color: Int, points: [(CGFloat, CGFloat)]) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 282))
        for (x, y) in points { path.addLine(to: CGPoint(x: x, y: y)) }
        path.addLine(to: CGPoint(x: 500, y: 282))
        path.closeSubpath()
        context.fill(path, with: .color(Self.color(color)))
    }

    private func drawFerry(_ context: inout GraphicsContext) {
        let ink = Self.color(0x302E42), warm = Self.color(0xF1B485)
        var hull = Path()
        hull.move(to: CGPoint(x: 104, y: 298))
        hull.addLine(to: CGPoint(x: 192, y: 298))
        hull.addQuadCurve(to: CGPoint(x: 220, y: 295), control: CGPoint(x: 210, y: 298))
        hull.addLine(to: CGPoint(x: 205, y: 306))
        hull.addLine(to: CGPoint(x: 115, y: 306))
        hull.closeSubpath()
        context.fill(hull, with: .color(ink))
        context.fill(Path(CGRect(x: 120, y: 287, width: 79, height: 11)), with: .color(ink))
        context.fill(Path(CGRect(x: 134, y: 280, width: 47, height: 7)), with: .color(ink))
        context.fill(Path(CGRect(x: 129, y: 278, width: 57, height: 2)), with: .color(ink))
        context.fill(Path(CGRect(x: 156, y: 266, width: 1.25, height: 13)), with: .color(ink))
        context.fill(Path(CGRect(x: 111, y: 286, width: 90, height: 2)), with: .color(ink))
        for i in 0..<12 {
            context.fill(Path(CGRect(x: 124 + 6 * i, y: 290, width: 3, height: 4)), with: .color(warm))
        }
        for i in 0..<7 {
            context.fill(Path(CGRect(x: 137 + 6 * i, y: 282, width: 3, height: 3)), with: .color(warm.opacity(0.83)))
        }
        var wake = Path()
        wake.move(to: CGPoint(x: 42, y: 311))
        wake.addQuadCurve(to: CGPoint(x: 122, y: 307), control: CGPoint(x: 98, y: 311))
        context.stroke(wake, with: .color(warm.opacity(0.73)), lineWidth: 1.35)
    }

    private static func color(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

private struct PaperNoise {
    private var seed: UInt32 = 0x7c5a1
    var unit: Double {
        mutating get {
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max)
        }
    }
}

struct StudioCompanion: View {
    let session: StudioSession

    var body: some View {
        ZStack {
            Color.black
            if let artwork = session.artwork {
                Image(nsImage: artwork)
                    .resizable().interpolation(.high).scaledToFill().blur(radius: 50)
                    .opacity(0.22).accessibilityHidden(true)
            }
            if let track = session.track {
                StudioCover(artwork: session.artwork, isPreview: session.isPreview)
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityElement().accessibilityLabel("Album artwork for " + track.title)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack").font(.system(size: 29, weight: .thin))
                        .foregroundStyle(.white.opacity(0.64))
                    Text("Album artwork").font(.title3.weight(.semibold))
                    Text(session.playerStatus).font(.callout)
                        .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.67))
                    Button("Connect to player", action: session.connect).buttonStyle(.bordered)
                }
                .frame(maxWidth: 330).padding(24).foregroundStyle(.white)
            }
        }
        .ignoresSafeArea().clipped()
    }
}
