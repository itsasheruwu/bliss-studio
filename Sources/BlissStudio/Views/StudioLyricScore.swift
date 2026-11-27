import CoreGraphics
import Foundation

/// The thread is a function of the playback position. Seeking into a reply or
/// back across a chorus reconstructs the same messages as uninterrupted playback.
nonisolated struct StudioLyricScore {
    struct Message: Identifiable {
        let id: Int
        let start: Double
        let end: Double?
        let text: String
        let words: [StudioWord]
        let accents: [StudioWordAccent?]
        let right: Bool
        let motif: Motif?
        let motifStart: Double
        let repeated: Bool
        let sceneEvents: [StudioLyricEvent]
        let twitterLinkStart: Double?
        var decorations: [StudioEffectsGraph.Block] = []
        var wordSlots: [Int] = []
        var quotedLyric: String? = nil
        var stickerImages: [UUID: CGImage] = [:]
        var cueStart: Double = 0

        func bubbleTint(at time: Double) -> StudioEffectsGraph.Tint? {
            block(.tint, at: time)?.tint
        }

        func block(_ effect: StudioEffectsGraph.Effect, at time: Double) -> StudioEffectsGraph.Block? {
            decorations.last { $0.effect == effect && cueStart + $0.delay <= time }
        }

        func textBlocks(for index: Int, at time: Double) -> [StudioEffectsGraph.Block] {
            decorations.filter {
                $0.effect.acceptsWord && cueStart + $0.delay <= time && ($0.word == nil || $0.word == wordSlots[index])
            }
        }

        func visibleWordCount(at time: Double) -> Int {
            words.partitionAfterStarts(through: time, start: \.start)
        }
    }

    enum Motif: Equatable {
        case asheville, eastRiver, brooklynBridge, ashes, stars, rain, heart

        var placeName: String? {
            switch self {
            case .asheville: "Asheville, North Carolina"
            case .eastRiver: "East River, New York"
            case .brooklynBridge: "Brooklyn Bridge, New York"
            default: nil
            }
        }
    }

    private(set) var messages: [Message] = []
    let duration: Double
    let estimatedTiming: Bool

    init(lines: [StudioLine] = [], title: String = "", artist: String = "", duration: Double = 0,
         effects: StudioEffectsGraph? = nil) {
        self.duration = duration
        estimatedTiming = lines.first?.isEstimated == true
        let isAshevilleRecording = Self.key(title) == "asheville" && Self.key(artist) == "glaive"
        let trees = StudioLyricEvent.isTrees(title: title, artist: artist)
        var turn = false
        var runLength = 0
        var delivery = StudioVocalPhrasing(lines: lines)
        var previousPhrase: [StudioWord] = []
        let edits = Dictionary((effects?.cues ?? []).map { ($0.anchor, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, line) in lines.enumerated() where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : duration
            let edit = edits[StudioEffectsGraph.Anchor(line)]
            let automatic = edit?.automatic ?? true
            let blocks = (edit?.blocks ?? [])
                .filter { line.start + $0.delay < min(line.end ?? nextStart, nextStart) || $0.delay == 0 }
                .sorted { $0.delay < $1.delay }
            let words = Self.timing(line, until: nextStart)
            guard !words.isEmpty else { continue }
            let phrases = Self.responses(in: words)
            let timed = !line.words.isEmpty && line.words.map(\.text).joined() == line.text
            let parenthetical = line.text.trimmingCharacters(in: .whitespaces).hasPrefix("(")
            // Keep phrases together for short turns; backing vocals always reply on the right.
            if phrases.count > 1 { turn = false; runLength = 0 }
            else if !parenthetical, runLength >= 3 { turn.toggle(); runLength = 0 }
            var wordSlot = -1
            var inWord = false
            for (part, phrase) in phrases.enumerated() {
                let source = phrase.map(\.text).joined()
                let link = automatic && trees ? Self.twitterLink(in: phrase, source: source) : nil
                let text = (link?.words.map(\.text).joined() ?? source).trimmingCharacters(in: .whitespacesAndNewlines)
                let keys = phrase.map { Self.key($0.text) }
                let cue = automatic ? Self.motif(in: phrase, keys: keys, text: text, isAshevilleRecording: isAshevilleRecording) : nil
                let end = part == phrases.count - 1 ? line.end : nil
                let automaticAccents = delivery.accents(words: phrase, keys: keys, lineEnd: end, timed: timed)
                let accents = automatic ? automaticAccents : Array(repeating: nil, count: phrase.count)
                var sung = Self.stutterSegments(in: link?.words ?? phrase, accents: accents, until: end ?? nextStart)
                if blocks.contains(where: { $0.effect.acceptsWord }) {
                    sung = Self.splitTextRuns(sung.words, accents: sung.accents)
                }
                let start = part == 0 ? line.start : phrase[0].start
                let nextPart = part + 1 < phrases.count ? phrases[part + 1][0].start : nextStart
                let phraseBlocks = blocks.filter {
                    let trigger = line.start + $0.delay
                    return trigger >= start && (trigger < nextPart || $0.delay == 0)
                }
                let slots = sung.words.map { word in
                    var firstSlot: Int?
                    for character in word.text {
                        if character.isWhitespace { inWord = false }
                        else {
                            if !inWord { wordSlot += 1; inWord = true }
                            if firstSlot == nil { firstSlot = wordSlot }
                        }
                    }
                    return firstSlot ?? wordSlot
                }
                let customEvents = phraseBlocks.compactMap { block -> StudioLyricEvent? in
                    guard let event = block.effect.event else { return nil }
                    let trigger = line.start + block.delay
                    let word = phrase.last { $0.start <= trigger } ?? phrase[0]
                    let text = event == .emoji ? block.glyph : event == .echo && block.delay == 0 ? source : word.text
                    return .init(kind: event, start: trigger, word: text, custom: true)
                }
                let defaults = automatic ? StudioLyricEvent.score(
                    phrase, trees: trees, previous: previousPhrase, linkStart: link?.start
                ) : []
                messages.append(Message(
                    id: index * 2 + part, start: start,
                    end: end,
                    text: text, words: sung.words, accents: sung.accents, right: part > 0 || parenthetical || turn,
                    motif: cue?.0, motifStart: cue?.1 ?? .infinity,
                    repeated: automatic && (2...8).contains(keys.count) && Set(keys).count == 1 && keys.first?.isEmpty == false,
                    sceneEvents: (defaults + customEvents).sorted { $0.start < $1.start },
                    twitterLinkStart: link?.start,
                    decorations: phraseBlocks.filter { $0.effect.event == nil && !$0.effect.acceptsWord }
                        + blocks.filter { $0.effect.acceptsWord },
                    wordSlots: slots,
                    quotedLyric: index > 0 ? lines[index - 1].text : nil,
                    stickerImages: Dictionary(phraseBlocks.compactMap { block in
                        block.image.flatMap(StudioStickerAsset.decode).map { (block.id, $0) }
                    }, uniquingKeysWith: { first, _ in first }),
                    cueStart: line.start
                ))
                previousPhrase = phrase
            }
            runLength += 1
        }
        messages.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    func activeIndex(at time: Double) -> Int? {
        let count = messages.partitionAfterStarts(through: time, start: \.start)
        return count > 0 ? count - 1 : nil
    }

    func isInterlude(after index: Int, at time: Double) -> Bool {
        guard let end = messages[index].end, time >= end else { return false }
        let next = index + 1 < messages.count ? messages[index + 1].start : duration
        return next - end >= (estimatedTiming ? 0.1 : 4)
    }

    private static func key(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Keep the source word clock, even when an enhanced LRC splits the domain across syllables.
    private static func twitterLink(in words: [StudioWord], source: String) -> (words: [StudioWord], start: Double)? {
        guard let match = source.firstMatch(of: #/(?i:\btalk(?:s|ing|in['’]?)?\s+on\s+[“‘"'(]*(twitter(?:\.com)?))(?![\w@/‐‑-]|\.[\w])/#)
        else { return nil }
        let target = NSRange(match.1.startIndex..<match.1.endIndex, in: source)
        let domain = "Twitter.com" as NSString
        var position = 0
        var start: Double?
        var result = words
        for (index, word) in words.enumerated() {
            let text = word.text as NSString
            let overlap = NSIntersectionRange(NSRange(location: position, length: text.length), target)
            if overlap.length > 0 {
                if start == nil { start = word.start }
                let beginning = overlap.location - target.location
                let length = NSMaxRange(overlap) == NSMaxRange(target) ? domain.length - beginning : overlap.length
                let letters = domain.substring(with: NSRange(location: beginning, length: length))
                let local = NSRange(location: overlap.location - position, length: overlap.length)
                result[index] = StudioWord(start: word.start, text: text.replacingCharacters(in: local, with: letters), end: word.end)
            }
            position += text.length
        }
        if let first = result.first, source.hasPrefix("he ") {
            result[0] = StudioWord(start: first.start, text: "H" + first.text.dropFirst(), end: first.end)
        }
        return start.map { (result, $0) }
    }

    private static func timing(_ line: StudioLine, until next: Double) -> [StudioWord] {
        if !line.words.isEmpty, line.words.map(\.text).joined() == line.text {
            var lastStart = line.start
            return line.words.map {
                lastStart = max(lastStart, $0.start.isFinite ? $0.start : lastStart)
                return StudioWord(start: lastStart, text: $0.text, end: $0.end)
            }
        }
        // Keep separators attached to their words so punctuation, line wrapping
        // and right-to-left ordering stay in the hands of the system text shaper.
        let matches = line.text.matches(of: #/\S+\s*/#)
        let tokens: [String]
        if matches.count == 1, line.text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            tokens = line.text.map(String.init)
        } else { tokens = matches.map { String($0.output) } }
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { sqrt(Double(max(1, $0.trimmingCharacters(in: .whitespacesAndNewlines).count))) }
        let total = weights.reduce(0, +)
        let available = (line.end ?? next) - line.start
        let allotted = max(0, available) * 0.87
        let span = line.isEstimated ? allotted : min(allotted, min(7, Double(tokens.count) * 0.45))
        var consumed = 0.0
        return zip(tokens, weights).map { text, weight in
            let start = line.start + consumed * span / total
            consumed += weight
            return StudioWord(start: start, text: text)
        }
    }

    /// An enhanced LRC can put several printed words under one timestamp.
    /// Keep that clock, but expose each printed word as a separate formatting run.
    private static func splitTextRuns(_ words: [StudioWord], accents: [StudioWordAccent?])
        -> (words: [StudioWord], accents: [StudioWordAccent?]) {
        var runs: [StudioWord] = []
        var styles: [StudioWordAccent?] = []
        for (word, accent) in zip(words, accents) {
            for match in word.text.matches(of: #/\S+\s*|\s+/#) {
                runs.append(.init(start: word.start, text: String(match.output), end: word.end))
                styles.append(accent)
            }
        }
        return (runs, styles)
    }

    private static func responses(in words: [StudioWord]) -> [[StudioWord]] {
        // A trailing parenthetical is a common encoding of a backing singer.
        // Leave inline asides, unbalanced parentheses and a whole-line aside intact.
        guard words.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(")") == true,
              let start = words.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("(") }),
              start > 0, words[start].start > words[0].start,
              words[start..<words.index(before: words.endIndex)].allSatisfy({ !$0.text.contains(")") })
        else { return [words] }
        return [Array(words[..<start]), Array(words[start...])]
    }

    /// Some lyric files transcribe several vocal attacks inside one timestamped token.
    /// Preserve every printed character while subdividing only the repeated prefix.
    private static func stutterSegments(in words: [StudioWord], accents: [StudioWordAccent?], until end: Double)
        -> (words: [StudioWord], accents: [StudioWordAccent?]) {
        guard words.contains(where: { $0.text.contains(where: { "-‐‑".contains($0) }) }) else { return (words, accents) }
        var result: [StudioWord] = []
        var stresses: [StudioWordAccent?] = []
        for (i, word) in words.enumerated() {
            let pieces = word.text.matches(of: #/[^‐‑-]+(?:[‐‑-]|$)/#).map { String($0.output) }
            let stems = pieces.map { $0.lowercased().filter(\.isLetter) }
            let bound = min(word.end ?? .infinity, i + 1 < words.count ? words[i + 1].start : end)
            guard (2...8).contains(pieces.count), pieces.joined() == word.text,
                  let stem = stems.first, (1...3).contains(stem.count),
                  let last = stems.last, last.count > stem.count, last.hasPrefix(stem),
                  stems.dropLast().allSatisfy({ $0 == stem }), bound > word.start else {
                result.append(word)
                stresses.append(accents[i])
                continue
            }
            let interval = min(0.145, (bound - word.start) / Double(pieces.count))
            for (n, piece) in pieces.enumerated() {
                let start = word.start + Double(n) * interval
                let final = n == pieces.count - 1
                result.append(StudioWord(start: start, text: piece, end: final ? word.end : start + interval))
                stresses.append(final ? accents[i] : .init(kind: .nod, duration: interval, strength: 0.85))
            }
        }
        return (result, stresses)
    }

    private static func motif(in words: [StudioWord], keys: [String], text: String, isAshevilleRecording: Bool) -> (Motif, Double)? {
        let phrase = text.lowercased()
        let named: (Motif, String)?
        if phrase.contains("east river") { named = (.eastRiver, "river") }
        else if phrase.contains("brooklyn bridge") { named = (.brooklynBridge, "bridge") }
        else if keys.contains("asheville") { named = (.asheville, "asheville") }
        else if isAshevilleRecording, let locality = keys.first(where: { $0 == "city" || $0 == "town" }) {
            named = (.asheville, locality)
        } else { named = nil }
        if let (place, token) = named {
            return (place, words[keys.firstIndex(of: token) ?? 0].start)
        }
        for (key, word) in zip(keys, words) {
            switch key {
            case "love", "heart": return (.heart, word.start)
            case "ash", "ashes", "embers": return (.ashes, word.start)
            case "constellation", "constellations", "stars", "starlight": return (.stars, word.start)
            case "rain", "rainfall", "raindrops": return (.rain, word.start)
            default: continue
            }
        }
        return nil
    }
}

nonisolated private extension Array {
    func partitionAfterStarts(through time: Double, start: KeyPath<Element, Double>) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if self[mid][keyPath: start] <= time { low = mid + 1 }
            else { high = mid }
        }
        return low
    }
}
