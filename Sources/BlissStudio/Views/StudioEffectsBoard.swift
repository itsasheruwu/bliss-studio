import SwiftUI

/// An effect is attached to the selected lyric as soon as it lands on the board.
struct StudioEffectsBoard: View {
    typealias Block = StudioEffectsGraph.Block
    typealias Position = StudioEffectsGraph.Position
    typealias Effect = StudioEffectsGraph.Effect

    let cue: StudioEffectsGraph.Cue
    let selected: UUID?
    let accent: Color
    let select: (UUID) -> Void
    let add: (Effect, Position?) -> Void
    let move: (UUID, Position) -> Void

    @GestureState private var drag: NodeDrag?
    @State private var acceptsDrop = false

    private struct NodeDrag {
        let id: UUID
        let translation: CGSize
    }

    private let coordinateSpace = "LyricEffectBoard"
    private let nodeWidth = 132.0
    private let root = CGPoint(x: 74, y: 70)

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(437, geo.size.width), height: max(156, 28 + Double((cue.blocks.count + 1) / 2) * 62))
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    wiring(size: size)
                    sourceNode
                        .position(root)
                    if cue.blocks.isEmpty {
                        Label("Drop an effect here", systemImage: "plus")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: max(203, size.width - 184), height: 98)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                            .position(x: (size.width + 155) / 2, y: 77)
                    }
                    ForEach(Array(cue.blocks.enumerated()), id: \.element.id) { index, block in
                        effectNode(block)
                            .position(center(for: block, index: index, size: size))
                            .zIndex(drag?.id == block.id ? 2 : selected == block.id ? 1 : 0)
                            .gesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named(coordinateSpace))
                                    .updating($drag) { value, state, _ in
                                        state = .init(id: block.id, translation: value.translation)
                                    }
                                    .onEnded { value in
                                        let origin = point(for: block, index: index, size: size)
                                        let end = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                                        select(block.id)
                                        move(block.id, position(at: end, size: size))
                                    }
                            )
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .coordinateSpace(name: coordinateSpace)
                .dropDestination(for: String.self) { items, location in
                    guard items.count == 1, let item = items.first, let effect = Effect(rawValue: item),
                          cue.blocks.count < StudioEffectsGraph.maximumBlocks else { return false }
                    add(effect, position(at: location, size: size))
                    return true
                } isTargeted: {
                    acceptsDrop = $0
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: 156)
        .background(.black.opacity(0.27), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(acceptsDrop ? accent : .white.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Effect graph")
    }

    private var sourceNode: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.circle.fill").foregroundStyle(accent)
            Text("Lyric starts").font(.callout.weight(.semibold))
        }
        .frame(width: 116, height: 40)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(accent.opacity(0.44))
        }
    }

    private func effectNode(_ block: Block) -> some View {
        let active = selected == block.id
        return Button {
            select(block.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: block.effect.symbol).foregroundStyle(accent)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.effect.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(block.delay == 0 ? block.effect.target.rawValue : String(format: "+%.2f s", block.delay))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(width: nodeWidth, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(white: active ? 0.16 : 0.115), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active ? accent : .white.opacity(0.16))
                .allowsHitTesting(false)
        }
        .help("Select to edit. Drag to move.")
    }

    private func wiring(size: CGSize) -> some View {
        Canvas { context, _ in
            let grid = 16
            for x in stride(from: 8, to: Int(size.width), by: grid) {
                for y in stride(from: 8, to: Int(size.height), by: grid) {
                    context.fill(Path(ellipseIn: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1.25, height: 1.25)),
                                 with: .color(.white.opacity(0.11)))
                }
            }
            let output = CGPoint(x: root.x + 58, y: root.y)
            for (index, block) in cue.blocks.enumerated() {
                let center = center(for: block, index: index, size: size)
                let input = CGPoint(x: center.x - nodeWidth / 2, y: center.y)
                let bend = (output.x + input.x) / 2
                let color = accent.opacity(selected == block.id ? 0.88 : 0.39)
                var path = Path()
                path.move(to: output)
                path.addCurve(to: input, control1: CGPoint(x: bend, y: output.y), control2: CGPoint(x: bend, y: input.y))
                context.stroke(path, with: .color(color), lineWidth: 1.5)
                context.fill(Path(ellipseIn: CGRect(x: input.x - 2.5, y: input.y - 2.5, width: 5, height: 5)), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func center(for block: Block, index: Int, size: CGSize) -> CGPoint {
        let origin = point(for: block, index: index, size: size)
        guard let drag, drag.id == block.id else { return origin }
        return clamped(CGPoint(x: origin.x + drag.translation.width, y: origin.y + drag.translation.height), size: size)
    }

    private func point(for block: Block, index: Int, size: CGSize) -> CGPoint {
        guard let position = block.position else {
            let x = 205 + (size.width - 283) * (index.isMultiple(of: 2) ? 0 : 1)
            return clamped(CGPoint(x: x, y: 40 + Double(index / 2) * 62), size: size)
        }
        return clamped(CGPoint(x: 205 + (size.width - 283) * position.x, y: 26 + (size.height - 52) * position.y), size: size)
    }

    private func position(at point: CGPoint, size: CGSize) -> Position {
        let point = clamped(point, size: size)
        return .init(x: (point.x - 205) / (size.width - 283), y: (point.y - 26) / (size.height - 52))
    }

    private func clamped(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: max(205, min(size.width - 78, point.x)), y: max(26, min(size.height - 26, point.y)))
    }
}
