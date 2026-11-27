import Foundation

/// Each edited lyric is a trigger with one outgoing connection per effect block.
nonisolated struct StudioEffectsGraph: Codable, Equatable {
    static let version = 1
    static let maximumBlocks = 12
    static let maximumBytes = 1_000_000

    var version = Self.version
    let song: String
    var cues: [Cue] = []

    struct Anchor: Codable, Hashable {
        let milliseconds: Int
        let lyric: String

        init(_ line: StudioLine) {
            // Use the source cue, independent of the player's visual timing offset.
            let start = line.start.isFinite ? min(max(0, line.start), 1_000_000) : 0
            milliseconds = Int((start * 1_000).rounded())
            lyric = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var start: Double { Double(milliseconds) / 1_000 }
    }

    struct Cue: Codable, Equatable {
        let anchor: Anchor
        var automatic = true
        var blocks: [Block] = []
    }

    struct Block: Codable, Equatable, Identifiable {
        var id = UUID()
        let effect: Effect
        var delay: Double = 0
        var tint: Tint = .gold
        var position: Position? = nil
        var word: Int? = nil
        var emoji: String? = nil
        var image: Data? = nil

        var glyph: String { emoji ?? "✨" }
    }

    struct Position: Codable, Equatable {
        var x: Double
        var y: Double
    }

    enum Target: String, CaseIterable {
        case reaction = "Tapbacks"
        case bubble = "Bubble"
        case screen = "Screen"
        case text = "Text effects"
        case formatting = "Text formatting"
        case details = "Message details"
    }

    enum Effect: String, Codable, CaseIterable, Identifiable {
        case heart, laugh, question, emphasize, thumbUp, thumbDown, emojiTapback
        case slam, loud, gentle, invisibleInk, stutter, tint
        case echo, spotlight, balloons, confetti, love, lasers, fireworks, shootingStar, celebration
        case sparks, ripple, rain
        case big, small, shake, nod, explode, textRipple, bloom, jitter
        case bold, italic, underline, strikethrough
        case sticker, emojiSticker, imageSticker, reply, delivered, read, typing

        var id: Self { self }

        var target: Target {
            switch self {
            case .heart, .laugh, .question, .emphasize, .thumbUp, .thumbDown, .emojiTapback: .reaction
            case .slam, .loud, .gentle, .invisibleInk, .stutter, .tint: .bubble
            case .echo, .spotlight, .balloons, .confetti, .love, .lasers, .fireworks, .shootingStar,
                    .celebration, .sparks, .ripple, .rain: .screen
            case .big, .small, .shake, .nod, .explode, .textRipple, .bloom, .jitter: .text
            case .bold, .italic, .underline, .strikethrough: .formatting
            case .sticker, .emojiSticker, .imageSticker, .reply, .delivered, .read, .typing: .details
            }
        }

        var title: String {
            switch self {
            case .heart: "Heart"
            case .laugh: "Laugh"
            case .question: "Question mark"
            case .emphasize: "Double exclamation"
            case .thumbUp: "Thumbs up"
            case .thumbDown: "Thumbs down"
            case .sticker: "Silver sticker"
            case .emojiTapback: "Emoji Tapback"
            case .emojiSticker: "Emoji sticker"
            case .imageSticker: "Image sticker"
            case .loud: "Loud"
            case .gentle: "Gentle"
            case .balloons: "Balloons"
            case .confetti: "Confetti"
            case .love: "Love"
            case .lasers: "Lasers"
            case .fireworks: "Fireworks"
            case .shootingStar: "Shooting star"
            case .celebration: "Celebration"
            case .big: "Big"
            case .small: "Small"
            case .shake: "Shake"
            case .nod: "Nod"
            case .explode: "Explode"
            case .textRipple: "Ripple"
            case .bloom: "Bloom"
            case .jitter: "Jitter"
            case .bold: "Bold"
            case .italic: "Italic"
            case .underline: "Underline"
            case .strikethrough: "Strikethrough"
            case .reply: "Quote previous lyric"
            case .delivered: "Delivered"
            case .read: "Read"
            case .typing: "Typing dots"
            case .slam: "Slam"
            case .echo: "Echo"
            case .invisibleInk: "Invisible ink"
            case .spotlight: "Spotlight"
            case .stutter: "Stutter"
            case .tint: "Tint"
            case .sparks: "Sparks"
            case .ripple: "Ripple"
            case .rain: "Rain"
            }
        }

        var symbol: String {
            switch self {
            case .heart: "heart.fill"
            case .laugh: "face.smiling"
            case .question: "questionmark"
            case .emphasize: "exclamationmark.2"
            case .thumbUp: "hand.thumbsup"
            case .thumbDown: "hand.thumbsdown"
            case .sticker: "seal"
            case .emojiTapback, .emojiSticker: "face.smiling.inverse"
            case .imageSticker: "photo"
            case .loud: "speaker.wave.3"
            case .gentle: "feather.fill"
            case .balloons: "balloon.2"
            case .confetti: "party.popper"
            case .love: "heart.circle"
            case .lasers: "laser.burst"
            case .fireworks: "fireworks"
            case .shootingStar: "star.leadinghalf.filled"
            case .celebration: "sparkler"
            case .big: "textformat.size.larger"
            case .small: "textformat.size.smaller"
            case .shake, .jitter: "waveform.path"
            case .nod: "arrow.up.and.down"
            case .explode: "burst"
            case .textRipple: "waveform.path"
            case .bloom: "camera.macro"
            case .bold: "bold"
            case .italic: "italic"
            case .underline: "underline"
            case .strikethrough: "strikethrough"
            case .reply: "arrowshape.turn.up.left"
            case .delivered: "checkmark"
            case .read: "checkmark.circle"
            case .typing: "ellipsis.bubble"
            case .slam: "arrow.down.to.line"
            case .echo: "rectangle.on.rectangle"
            case .invisibleInk: "eye.slash"
            case .spotlight: "light.max"
            case .stutter: "waveform.path"
            case .tint: "paintpalette"
            case .sparks: "sparkles"
            case .ripple: "circle.dotted.circle"
            case .rain: "cloud.rain"
            }
        }

        var acceptsColor: Bool {
            (target == .screen && self != .echo) || self == .tint
        }

        var acceptsEmoji: Bool { self == .emojiTapback || self == .emojiSticker }
        var acceptsWord: Bool { target == .text || target == .formatting }

        var wordAccent: StudioWordAccent? {
            guard target == .text,
                  let kind = StudioWordAccent.Kind(rawValue: self == .textRipple ? "ripple" : rawValue)
            else { return nil }
            return .init(kind: kind, duration: 0.78, strength: 1)
        }

        var event: StudioLyricEvent.Kind? {
            switch self {
            case .heart: .heart
            case .laugh: .laugh
            case .question: .question
            case .emphasize: .emphasize
            case .thumbUp: .thumbUp
            case .thumbDown: .thumbDown
            case .sticker: .slowSilver
            case .slam: .slam
            case .echo: .echo
            case .invisibleInk: .invisibleInk
            case .loud: .loud
            case .gentle: .gentle
            case .emojiTapback: .emoji
            case .stutter: .stutter
            default: nil
            }
        }
    }

    enum Tint: String, Codable, CaseIterable {
        case gold, coral, mint, violet, blue
        var title: String { rawValue.capitalized }
    }

    mutating func set(_ cue: Cue) {
        if let index = cues.firstIndex(where: { $0.anchor == cue.anchor }) {
            if cue.automatic && cue.blocks.isEmpty { cues.remove(at: index) }
            else { cues[index] = cue }
        } else if !cue.automatic || !cue.blocks.isEmpty {
            cues.append(cue)
        }
    }

    func validate(lines: [StudioLine]? = nil) throws {
        guard version == Self.version else { throw GraphError.version }
        guard song.utf8.count <= 512, cues.count <= 512,
              Set(cues.map(\.anchor)).count == cues.count,
              cues.allSatisfy({ cue in
                  (0...1_000_000_000).contains(cue.anchor.milliseconds) &&
                  !cue.anchor.lyric.isEmpty && cue.anchor.lyric.utf8.count <= 4_096 &&
                  cue.blocks.count <= Self.maximumBlocks &&
                  Set(cue.blocks.map(\.id)).count == cue.blocks.count &&
                  cue.blocks.allSatisfy { block in
                      (0...8).contains(block.delay) &&
                      (block.word.map { block.effect.acceptsWord && cue.anchor.lyric.split(whereSeparator: \.isWhitespace).indices.contains($0) } ?? true) &&
                      (block.emoji.map { block.effect.acceptsEmoji && Self.isEmoji($0) } ?? true) &&
                      (block.image.map { block.effect == .imageSticker && StudioStickerAsset.decode($0) != nil } ?? true) &&
                      (block.position.map {
                          (0...1).contains($0.x) && (0...1).contains($0.y)
                      } ?? true)
                  }
              }) else { throw GraphError.invalid }
        if let lines {
            let originals = Set(lines.map(Anchor.init))
            guard cues.allSatisfy({ originals.contains($0.anchor) }) else { throw GraphError.wrongLyrics }
        }
    }

    static func isEmoji(_ value: String) -> Bool {
        value.count == 1 && value.utf8.count <= 48 &&
            (value.unicodeScalars.contains { $0.properties.isEmojiPresentation } ||
             (value.unicodeScalars.contains("\u{FE0F}") && value.unicodeScalars.contains { $0.properties.isEmoji }))
    }

    enum GraphError: LocalizedError {
        case invalid, version, wrongLyrics, songChanged, sticker

        var errorDescription: String? {
            switch self {
            case .invalid: "Choose a valid lyric effects .bliss file under 1 MB."
            case .version: "This .bliss file needs a different version of Bliss Studio."
            case .wrongLyrics: "This file’s lyric text or timestamps don’t match this song. Load the matching lyrics first."
            case .songChanged: "The song changed. Reopen lyric effects for the current song."
            case .sticker: "Choose an image under 12 MB for this sticker."
            }
        }
    }
}

nonisolated struct StudioEffectsStore {
    var directory = StudioLibrary.directory.appending(path: "Lyric Effects")

    func load(for track: StudioTrack) throws -> StudioEffectsGraph? {
        do { return try Self.read(location(for: track)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    }

    func save(_ graph: StudioEffectsGraph?, for track: StudioTrack) throws {
        let url = location(for: track)
        if let graph {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.write(graph, to: url)
        } else {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    private func location(for track: StudioTrack) -> URL {
        directory.appending(path: StudioLyrics.recordingKey(track)).appendingPathExtension("bliss")
    }

    static func read(_ url: URL) throws -> StudioEffectsGraph {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: StudioEffectsGraph.maximumBytes + 1),
              data.count <= StudioEffectsGraph.maximumBytes,
              let graph = try? JSONDecoder().decode(StudioEffectsGraph.self, from: data)
        else { throw StudioEffectsGraph.GraphError.invalid }
        try graph.validate()
        return graph
    }

    static func write(_ graph: StudioEffectsGraph, to url: URL) throws {
        try graph.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(graph)
        guard data.count <= StudioEffectsGraph.maximumBytes else { throw StudioEffectsGraph.GraphError.invalid }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
}
