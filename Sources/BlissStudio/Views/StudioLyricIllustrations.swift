import SwiftUI

struct SceneWordAtmosphere: View {
    let motif: StudioLyricScore.Motif
    let elapsed: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let strength = min(1, elapsed * 7)
            var constellation = Path()
            for index in 0..<18 {
                let seed = Double(index)
                let x0 = (seed * 0.618034 + 0.13).truncatingRemainder(dividingBy: 1)
                let y0 = (seed * 0.386 + 0.21).truncatingRemainder(dividingBy: 1)
                var x = x0 * size.width, y = y0 * size.height
                switch motif {
                case .ashes:
                    y = size.height * (1 - (y0 + elapsed * (0.11 + 0.025 * x0)).truncatingRemainder(dividingBy: 1))
                    x += sin(seed + elapsed * 1.2) * 8
                case .rain:
                    y = (y0 + elapsed * 0.52).truncatingRemainder(dividingBy: 1) * size.height
                    var drop = Path()
                    drop.move(to: .init(x: x, y: y))
                    drop.addLine(to: .init(x: x - 1.6, y: y + 5))
                    context.stroke(drop, with: .color(tint.opacity(0.30 * strength)), lineWidth: 1)
                    continue
                case .stars:
                    if index == 0 { constellation.move(to: CGPoint(x: x, y: y)) }
                    else if index < 6 { constellation.addLine(to: CGPoint(x: x, y: y)) }
                default: continue
                }
                let radius = index.isMultiple(of: 4) ? 1.8 : 1.0
                context.fill(Path(ellipseIn: .init(x: x, y: y, width: radius * 2, height: radius * 2)),
                             with: .color(tint.opacity((0.26 + 0.29 * x0) * strength)))
            }
            if motif == .stars {
                context.stroke(constellation.trimmedPath(from: 0, to: min(1, elapsed * 1.7)),
                               with: .color(tint.opacity(0.27)), lineWidth: 0.7)
            }
        }
        .accessibilityHidden(true)
    }
}
