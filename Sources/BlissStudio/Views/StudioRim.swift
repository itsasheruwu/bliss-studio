import SwiftUI

extension StudioPalette {
    func applying(_ mode: StudioPaletteMode) -> Self {
        switch mode {
        case .artwork: self
        case .dusk: .dusk
        case .tide: .init(primary: .init(red: 0.12, green: 0.81, blue: 0.75),
                          secondary: .init(red: 0.28, green: 0.44, blue: 0.94),
                          highlight: .init(red: 0.73, green: 0.96, blue: 0.91))
        case .ember: .init(primary: .init(red: 1.0, green: 0.38, blue: 0.13),
                           secondary: .init(red: 0.76, green: 0.14, blue: 0.31),
                           highlight: .init(red: 1.0, green: 0.86, blue: 0.63))
        }
    }
}

struct StudioDesktopRim: View {
    let session: StudioSession
    let notch: CGRect?

    var body: some View {
        Color.clear.overlay {
            if session.hasLivePlayback, session.lightIntensity > 0 {
                StudioRim(session: session, notch: notch, revealOnAppear: true)
            }
        }
    }
}

/// The same optical profile follows the window or the physical bezel, including the camera lip.
struct StudioRim: View {
    let session: StudioSession
    var notch: CGRect? = nil
    var revealOnAppear = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artworkPalette = StudioPalette.dusk
    @State private var appearedAt = ProcessInfo.processInfo.systemUptime
    @State private var revealFinished = false
    private static let revealDuration = 1.0

    var body: some View {
        let intensity = session.lightIntensity
        let moves = session.animateLight && !reduceMotion
        let reactive = session.reactive && !session.isPreview && !reduceMotion
        let followsBeat = session.beatSync && !session.isPreview && !reduceMotion && session.track?.isPlaying != false
        let revealing = revealOnAppear && !reduceMotion && !revealFinished
        let redraws = reactive || followsBeat || moves || revealing
        if intensity > 0 {
            TimelineView(.animation(minimumInterval: 1 / 30.0, paused: !redraws)) { _ in
                let phase = session.rimPhase(moving: moves)
                let level = reactive ? min(1, max(0, session.audioLevel)) : 0
                let pulse = reactive ? min(1, max(0, session.audioPulse)) : 0
                let beat = followsBeat ? session.audioBeat : 0
                let palette = artworkPalette.applying(session.paletteMode)
                let width = min(16, max(1, session.lightWidth))
                let elapsed = ProcessInfo.processInfo.systemUptime - appearedAt
                let fraction = revealing ? min(1, max(0, elapsed / Self.revealDuration)) : 1
                let progress = fraction * fraction * (3 - 2 * fraction)
                Canvas { context, size in
                    guard size.width > 1, size.height > 1 else { return }
                    let outline = Self.perimeter(in: size, notch: notch)
                    let stroke = Self.revealedStroke(outline, progress: progress)
                    let light = shadings(in: size, phase: phase, moving: moves, palette: palette, accent: max(pulse, beat))
                    let breadth = width * (0.96 + 0.25 * level + 0.57 * pulse + 1.04 * beat)
                    context.clip(to: outline)
                    func bloom(breadth scale: Double, blur: Double, opacity: Double) {
                        context.drawLayer { layer in
                            layer.addFilter(.blur(radius: blur))
                            layer.opacity = opacity
                            layer.stroke(stroke, with: light.halo,
                                         style: StrokeStyle(lineWidth: breadth * scale, lineCap: .round, lineJoin: .round))
                        }
                    }
                    bloom(breadth: 6.0, blur: breadth * 1.7, opacity: 0.60 + 0.12 * pulse + 0.19 * beat)
                    bloom(breadth: 2.8, blur: max(0.8, breadth * 0.51), opacity: 0.94)
                    context.stroke(stroke, with: light.core,
                                   style: StrokeStyle(lineWidth: max(1, breadth * 1.24), lineCap: .round, lineJoin: .round))
                }
            }
            .opacity(intensity)
            .onChange(of: session.artwork, initial: true) { _, image in artworkPalette = .from(image) }
            .task {
                guard revealOnAppear else { return }
                try? await Task.sleep(for: .seconds(Self.revealDuration))
                guard !Task.isCancelled else { return }
                revealFinished = true
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    // Sample the narrow leading edge and the long tail in their own coordinates. They
    // keep their full brightness between frames, even when crossing the gradient seam.
    private static let stops = [0.0, 0.010, 0.021, 0.034, 0.055, 0.10, 0.18, 0.30, 0.43,
                                0.54, 0.66, 0.74, 0.82, 0.88, 0.925, 0.95, 0.97, 0.986]

    private func shadings(in size: CGSize, phase: Double, moving: Bool, palette: StudioPalette,
                          accent: Double) -> (core: GraphicsContext.Shading, halo: GraphicsContext.Shading) {
        let start = moving ? phase : 0
        let highlight = palette.highlight.mix(with: .white, by: 0.68)
        func colors(at offset: Double) -> (core: Color, halo: Color) {
            let angle = offset * 2 * .pi
            let base = palette.primary.mix(with: palette.secondary, by: 0.5 + 0.48 * sin(angle * 2 - 0.7))
            guard moving else {
                let wash = 0.23 + 0.38 * pow(0.5 + 0.5 * cos(angle * 2 - 0.6), 2)
                let light = base.mix(with: palette.highlight, by: 0.13 + 0.32 * accent)
                return (light.opacity(min(1, wash + 0.27 * accent)), base.opacity(min(1, wash + 0.21 * accent)))
            }
            let distance = offset > 0.5 ? offset - 1 : offset
            let headWidth = distance < 0 ? 0.040 : 0.016
            let tailWidth = distance < 0 ? 0.15 : 0.035
            let head = exp(-0.5 * pow(distance / headWidth, 2))
            let tail = exp(-0.5 * pow(distance / tailWidth, 2))
            let core = base.mix(with: highlight, by: head)
            let halo = base.mix(with: palette.highlight, by: head * (0.23 + 0.24 * accent))
            return (core.opacity(min(1, 0.075 + 0.69 * tail + 0.35 * head + 0.10 * accent)),
                    halo.opacity(min(1, 0.11 + 0.91 * tail + 0.15 * accent)))
        }
        let seam = colors(at: start == 0 ? 0 : 1 - start)
        var core = [Gradient.Stop(color: seam.core, location: 0)]
        var halo = [Gradient.Stop(color: seam.halo, location: 0)]
        // The right midpoint is where SwiftUI wraps a conic gradient. Emit both sides
        // of that point with matching ink and all intervening stops in circular order.
        let split = Self.stops.firstIndex { $0 + start >= 1 } ?? Self.stops.endIndex
        for i in Self.stops.indices {
            let offset = Self.stops[(split + i) % Self.stops.count]
            let fraction = (start + offset).truncatingRemainder(dividingBy: 1)
            guard fraction > 0 else { continue }
            let location = StudioRimMotion.gradientLocation(at: fraction, in: size)
            let ink = colors(at: offset)
            core.append(.init(color: ink.core, location: location))
            halo.append(.init(color: ink.halo, location: location))
        }
        core.append(.init(color: seam.core, location: 1))
        halo.append(.init(color: seam.halo, location: 1))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return (.conicGradient(Gradient(stops: core), center: center), .conicGradient(Gradient(stops: halo), center: center))
    }

    static func revealedStroke(_ outline: Path, progress: Double) -> Path {
        if progress >= 1 { return outline }
        let reach = progress / 2
        var stroke = outline.trimmedPath(from: 0, to: reach)
        stroke.addPath(outline.trimmedPath(from: 1 - reach, to: 1))
        return stroke
    }

    // Begin at the top center or the middle of the notch lip, so trimming
    // from both ends sends the light in opposite directions from that point.
    static func perimeter(in size: CGSize, notch: CGRect?) -> Path {
        let notch = notch.flatMap { notch in
            notch.width > 8 && notch.maxY > 3 && notch.minX > 8 && notch.maxX < size.width - 8 ? notch : nil
        }
        let origin = CGPoint(x: notch?.midX ?? size.width / 2, y: notch?.maxY ?? 0)
        var path = Path()
        path.move(to: origin)
        let lip = notch.map { min(9, $0.maxY * 0.38, $0.width * 0.18) } ?? 0
        let shoulder = min(4, lip * 0.65)
        if let notch {
            path.addLine(to: CGPoint(x: notch.maxX - lip, y: notch.maxY))
            path.addQuadCurve(to: CGPoint(x: notch.maxX, y: notch.maxY - lip), control: CGPoint(x: notch.maxX, y: notch.maxY))
            path.addLine(to: CGPoint(x: notch.maxX, y: shoulder))
            path.addQuadCurve(to: CGPoint(x: notch.maxX + shoulder, y: 0), control: CGPoint(x: notch.maxX, y: 0))
        }
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: .zero)
        if let notch {
            path.addLine(to: CGPoint(x: notch.minX - shoulder, y: 0))
            path.addQuadCurve(to: CGPoint(x: notch.minX, y: shoulder), control: CGPoint(x: notch.minX, y: 0))
            path.addLine(to: CGPoint(x: notch.minX, y: notch.maxY - lip))
            path.addQuadCurve(to: CGPoint(x: notch.minX + lip, y: notch.maxY), control: CGPoint(x: notch.minX, y: notch.maxY))
        }
        path.closeSubpath()
        return path
    }
}
