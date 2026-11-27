import SwiftUI
import UniformTypeIdentifiers

struct StudioEffectsEditor: View {
    let session: StudioSession
    let track: StudioTrack
    let palette: StudioPalette
    let done: () -> Void

    @State private var selection: Int?
    @State private var selectedBlockID: UUID?
    @State private var filter = ""
    @State private var effectTarget: StudioEffectsGraph.Target = .bubble
    @State private var preview = StudioLyricScore()
    @State private var previewStarted: Date?
    @State private var previewStart = 0.0
    @State private var previewEnd = 0.0
    @State private var emojiInput = ""
    @State private var error: String?
    @State private var pendingImport: StudioEffectsGraph?
    @State private var confirmReplace = false
    @State private var confirmReset = false

    private var graph: StudioEffectsGraph {
        session.lyricEffects ?? .init(song: track.title)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                toolbar(compact: geo.size.width < 670)
                Divider()
                HSplitView {
                    lyricsList.frame(minWidth: 140, idealWidth: 225, maxWidth: 285)
                    if let index = selection, session.lyrics.indices.contains(index) {
                        let line = session.lyrics[index]
                        let anchor = StudioEffectsGraph.Anchor(line)
                        let cue = graph.cues.first { $0.anchor == anchor } ?? .init(anchor: anchor)
                        workspace(line: line, cue: cue)
                            .frame(minWidth: 230, maxWidth: .infinity)
                    }
                }
            }
        }
        .background(Color(red: 0.069, green: 0.067, blue: 0.083))
        .onAppear {
            let position = session.position(at: .now) + session.lyricOffset
            selection = session.lyrics.lastIndex { $0.start <= position } ?? session.lyrics.indices.first
        }
        .onChange(of: selection, initial: true) {
            selectedBlockID = nil
            previewStarted = nil
            rebuildPreview()
        }
        .onChange(of: session.lyrics) {
            if let selection, !session.lyrics.indices.contains(selection) {
                self.selection = session.lyrics.indices.first
            }
            rebuildPreview()
        }
        .onChange(of: session.lyricEffects) { rebuildPreview() }
        .onChange(of: selectedBlockID) {
            emojiInput = graph.cues.lazy.flatMap(\.blocks).first { $0.id == selectedBlockID }?.glyph ?? ""
        }
        .task(id: previewStarted) {
            guard previewStarted != nil else { return }
            try? await Task.sleep(for: .seconds(max(0.25, previewEnd - previewStart)))
            if !Task.isCancelled { previewStarted = nil }
        }
        .alert("Lyric effects", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog("Replace this song’s lyric effects?", isPresented: $confirmReplace) {
            Button("Replace Effects", role: .destructive) {
                if let pendingImport { save(pendingImport) }
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The imported blocks will replace the custom effects for \(track.title).")
        }
        .confirmationDialog("Reset this song’s lyric effects?", isPresented: $confirmReset) {
            Button("Reset Effects", role: .destructive) { save(nil) }
        } message: {
            Text("This removes the custom blocks and restores Bliss Studio’s automatic effects for \(track.title).")
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lyric effects").font(.headline)
                Text(track.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if compact {
                Menu {
                    fileActions
                } label: {
                    Label("Effect files", systemImage: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                fileActions
            }
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 11)
        .padding(.bottom, 9)
        .padding(.leading, 82)
        .padding(.trailing, 15)
    }

    @ViewBuilder private var fileActions: some View {
        Button("Import…", action: importGraph).help("Import lyric effects from a .bliss or legacy .graft file")
        Button("Export…", action: exportGraph).help("Export this song’s lyric effects as a .bliss file")
        Button("Reset…") { confirmReset = true }
            .disabled(session.lyricEffects == nil)
            .help("Restore automatic lyric effects for this song")
    }

    private var lyricsList: some View {
        VStack(spacing: 8) {
            TextField("Find a lyric", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            ScrollViewReader { scroll in
                List(selection: $selection) {
                    ForEach(session.lyrics.indices.filter { filter.isEmpty || session.lyrics[$0].text.localizedCaseInsensitiveContains(filter) },
                            id: \.self) { index in
                        let line = session.lyrics[index]
                        let cue = graph.cues.first { $0.anchor == .init(line) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.time(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(line.text).lineLimit(2)
                            Spacer(minLength: 0)
                            if let cue {
                                Image(systemName: cue.blocks.isEmpty ? "minus.circle" : "sparkle")
                                    .font(.caption)
                                    .foregroundStyle(palette.highlight)
                                    .accessibilityLabel(cue.blocks.isEmpty ? "Automatic effects off" : "Custom effects")
                            }
                        }
                        .tag(index)
                        .id(index)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onAppear { if let selection { scroll.scrollTo(selection, anchor: .center) } }
                .accessibilityLabel("Lyrics")
            }
        }
        .background(.black.opacity(0.20))
    }

    private func workspace(line: StudioLine, cue: StudioEffectsGraph.Cue) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Preview").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        previewStarted = .now
                    } label: {
                        Label("Replay", systemImage: "play.fill")
                    }
                    .help("Replay this lyric’s effects")
                }
                previewStage
                HStack {
                    Text("Effect blocks").font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Automatic effects", isOn: Binding(
                        get: { cue.automatic },
                        set: { value in
                            var updated = cue
                            updated.automatic = value
                            update(updated)
                        }
                    ))
                    .help("Keep Bliss Studio’s automatic effects on this lyric")
                    .toggleStyle(.checkbox)
                    .fixedSize()
                }
                StudioEffectsBoard(cue: cue, selected: selectedBlockID, accent: palette.highlight,
                    select: { selectedBlockID = $0 },
                    add: { add($0, to: cue, position: $1) },
                    move: { id, position in
                        change(id, in: cue) { $0.position = position }
                    })
                if let block = cue.blocks.first(where: { $0.id == selectedBlockID }) {
                    inspector(block, cue: cue, line: line)
                }
                library(cue)
            }
            .padding(15)
        }
    }

    private var previewStage: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [palette.highlight.opacity(0.13), .clear],
                               center: .center, startRadius: 4, endRadius: 240)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: previewStarted == nil)) { timeline in
                    let elapsed = previewStarted.map { max(0, timeline.date.timeIntervalSince($0)) }
                    let end = max(previewStart, previewEnd - 0.005)
                    let time = elapsed.map { min(end, previewStart + $0) } ?? end
                    StudioLyricThread(score: preview, time: time, palette: palette,
                                          availableSize: geo.size, reduceMotion: reduceMotion)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(height: 143)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func inspector(_ block: StudioEffectsGraph.Block, cue: StudioEffectsGraph.Cue,
                           line: StudioLine) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { blockControls(block, cue: cue, line: line) }
            VStack(alignment: .leading, spacing: 9) { blockControls(block, cue: cue, line: line) }
        }
        .font(.callout)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func blockControls(_ block: StudioEffectsGraph.Block, cue: StudioEffectsGraph.Cue,
                                             line: StudioLine) -> some View {
        Label(block.effect.title, systemImage: block.effect.symbol).fontWeight(.semibold)
        let limit = max(0, min(8, (min(line.end ?? nextStart, nextStart) - line.start - 0.05)))
        let delay = Binding(
            get: { min(limit, block.delay) },
            set: { value in
                guard value.isFinite else { return }
                change(block.id, in: cue, preview: true) { $0.delay = min(limit, max(0, value)) }
            }
        )
        HStack(spacing: 5) {
            Text("Delay")
            TextField("Delay", value: delay, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 48)
                .accessibilityLabel("Effect delay in seconds")
            Text("s").foregroundStyle(.secondary)
            Stepper("Effect delay", value: delay, in: 0...limit, step: 0.05)
                .labelsHidden()
        }
        .help("Seconds after the lyric starts. Set to zero to start immediately.")
        .fixedSize()
        if block.effect.acceptsColor {
            Picker("Color", selection: Binding(
                get: { block.tint },
                set: { value in change(block.id, in: cue, preview: true) { $0.tint = value } }
            )) {
                ForEach(StudioEffectsGraph.Tint.allCases, id: \.self) { tint in
                    Text(tint.title).tag(tint)
                }
            }
            .fixedSize()
        }
        if block.effect.acceptsWord {
            Picker("Apply to", selection: Binding(
                get: { block.word },
                set: { value in change(block.id, in: cue, preview: true) { $0.word = value } }
            )) {
                Text("Whole lyric").tag(nil as Int?)
                ForEach(Array(line.text.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { index, word in
                    Text(String(word)).tag(Optional(index))
                }
            }
            .fixedSize()
        }
        if block.effect.acceptsEmoji {
            HStack(spacing: 5) {
                TextField("Emoji", text: $emojiInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit { applyEmoji(block, cue: cue) }
                    .accessibilityLabel("Custom emoji")
                Button("Apply") { applyEmoji(block, cue: cue) }
                    .disabled(emojiInput == block.glyph)
            }
            .help("Paste one emoji or open the Mac emoji picker with Control–Command–Space.")
        }
        if block.effect == .imageSticker {
            Button(block.image == nil ? "Choose image…" : "Replace image…") {
                chooseSticker(block, cue: cue)
            }
        }
        Button(role: .destructive) {
            var updated = cue
            updated.blocks.removeAll { $0.id == block.id }
            if update(updated) { selectedBlockID = nil }
        } label: {
            Label("Remove block", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .help("Remove selected effect block")
    }

    private func library(_ cue: StudioEffectsGraph.Cue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Add an effect").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Effect category", selection: $effectTarget) {
                    ForEach(StudioEffectsGraph.Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(StudioEffectsGraph.Effect.allCases.filter { $0.target == effectTarget }) { effect in
                        Button {
                            add(effect, to: cue, position: nil)
                        } label: {
                            Label(effect.title, systemImage: effect.symbol)
                        }
                        .controlSize(.small)
                        .draggable(effect.rawValue)
                        .help("Click or drag onto the graph")
                    }
                }
            }
            .disabled(cue.blocks.count >= StudioEffectsGraph.maximumBlocks)
        }
    }

    private var nextStart: Double {
        guard let selection, session.lyrics.indices.contains(selection + 1) else { return track.duration }
        return session.lyrics[selection + 1].start
    }

    private func rebuildPreview() {
        guard let selection, session.lyrics.indices.contains(selection) else {
            preview = .init()
            return
        }
        let line = session.lyrics[selection]
        previewStart = line.start
        previewEnd = max(line.start + 0.005, min(nextStart, line.end ?? nextStart, line.start + 9.5))
        preview = StudioLyricScore(lines: session.lyrics, title: track.title, artist: track.artist,
                                       duration: track.duration, effects: graph)
    }

    private func add(_ effect: StudioEffectsGraph.Effect, to cue: StudioEffectsGraph.Cue,
                     position: StudioEffectsGraph.Position?) {
        guard cue.blocks.count < StudioEffectsGraph.maximumBlocks else { return }
        var updated = cue
        let block = StudioEffectsGraph.Block(effect: effect, position: position)
        updated.blocks.append(block)
        if update(updated) {
            selectedBlockID = block.id
            previewStarted = .now
        }
    }

    private func change(_ id: UUID, in cue: StudioEffectsGraph.Cue, preview: Bool = false,
                        apply: (inout StudioEffectsGraph.Block) -> Void) {
        guard var updated = graph.cues.first(where: { $0.anchor == cue.anchor }),
              let index = updated.blocks.firstIndex(where: { $0.id == id }) else { return }
        apply(&updated.blocks[index])
        if update(updated), preview { previewStarted = .now }
    }

    private func chooseSticker(_ block: StudioEffectsGraph.Block, cue: StudioEffectsGraph.Cue) {
        let panel = NSOpenPanel()
        panel.title = "Choose an image for the sticker"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let image = try StudioStickerAsset.importImage(url)
                change(block.id, in: cue, preview: true) { $0.image = image }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func applyEmoji(_ block: StudioEffectsGraph.Block, cue: StudioEffectsGraph.Cue) {
        let value = emojiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StudioEffectsGraph.isEmoji(value) else {
            error = "Choose one emoji for this block."
            return
        }
        change(block.id, in: cue, preview: true) { $0.emoji = value }
    }

    @discardableResult private func update(_ cue: StudioEffectsGraph.Cue) -> Bool {
        var updated = graph
        updated.set(cue)
        return save(updated.cues.isEmpty ? nil : updated)
    }

    @discardableResult private func save(_ graph: StudioEffectsGraph?) -> Bool {
        do {
            try session.saveLyricEffects(graph, trackID: track.id)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func importGraph() {
        let panel = NSOpenPanel()
        panel.title = "Import lyric effects"
        panel.allowedContentTypes = ["bliss", "graft"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard ["bliss", "graft"].contains(url.pathExtension.lowercased()) else { throw StudioEffectsGraph.GraphError.invalid }
                let imported = try StudioEffectsStore.read(url)
                try imported.validate(lines: session.lyrics)
                if session.lyricEffects == nil { save(imported) }
                else { pendingImport = imported; confirmReplace = true }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func exportGraph() {
        let exported = graph
        let panel = NSSavePanel()
        panel.title = "Export lyric effects"
        panel.allowedContentTypes = [.init(filenameExtension: "bliss") ?? .data]
        panel.nameFieldStringValue = track.title.replacingOccurrences(of: "/", with: "-") + ".bliss"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try StudioEffectsStore.write(exported, to: url) }
            catch { self.error = error.localizedDescription }
        }
    }

    private static func time(_ time: Double) -> String {
        let centiseconds = Int(max(0, (time * 100).rounded()))
        return String(format: "%d:%02d.%02d", centiseconds / 6_000, (centiseconds / 100) % 60, centiseconds % 100)
    }
}
