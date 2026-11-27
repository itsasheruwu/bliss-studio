import Foundation

nonisolated struct StudioLyricEvent: Equatable {
    enum Kind: Equatable {
        case slowSilver, heart, question, emphasize, laugh, thumbUp, thumbDown, emoji
        case echo, slam, loud, gentle, invisibleInk, spotlight, stutter

        var isReaction: Bool {
            switch self {
            case .slowSilver, .heart, .question, .emphasize, .laugh, .thumbUp, .thumbDown, .emoji: true
            default: false
            }
        }
    }

    let kind: Kind
    let start: Double
    let word: String
    var custom = false

    static func isTrees(title: String, artist: String) -> Bool {
        let recording = title.lowercased().split(whereSeparator: { "([".contains($0) }).first?
            .trimmingCharacters(in: .whitespaces)
        let artists = artist.lowercased().split(whereSeparator: { !$0.isLetter })
        return recording == "trees" && artists.contains("kurtains")
    }

    static func score(_ words: [StudioWord], trees: Bool, previous: [StudioWord] = [], linkStart: Double? = nil) -> [Self] {
        func token(_ word: StudioWord) -> String { word.text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let tokens = words.map(token)
        // A line break can split the collective name from its final sung number.
        var prefix: [String] = []
        if let last = previous.last, let first = words.first, first.start >= last.start,
           first.start - (last.end ?? last.start) <= 1.8 {
            prefix = previous.suffix(5).map(token)
        }
        let tagTokens = prefix + tokens
        let written = writtenReaction(in: words, tokens: tokens)
        var events: [Self] = []
        for index in words.indices {
            let key = tokens[index]
            let text = words[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            func add(_ kind: Kind) {
                if kind.isReaction, kind != .slowSilver, events.contains(where: { $0.kind == kind }) { return }
                events.append(Self(kind: kind, start: words[index].start, word: text))
            }
            // Match whole sung tokens; the stamp arrives on the completing syllable.
            // The spelling can be a single producer tag or split into six timed words.
            let tagIndex = prefix.count + index
            if ["3", "three"].contains(where: { key.hasSuffix($0) }),
               (max(0, tagIndex - 5)...tagIndex).contains(where: { first in
                   let tag = tagTokens[first...tagIndex].joined()
                   return tag.wholeMatch(of: #/(?:slowsilver|doubles|ss)(?:0|zero|oh|o)(?:3|three)/#) != nil
               }) {
                add(.slowSilver)
            }
            if trees {
                let prior = index > 0 ? tokens[index - 1] : ""
                switch key {
                case "tre", "tree", "trees", "tretretree", "tretrees", "tretree":
                    if prior != "tre" { add(.stutter) }
                case "blah", "tick":
                    if prior != key { add(.echo) }
                    else if key == "blah", index == 1 || tokens[index - 2] != key { add(.laugh) }
                case "squeezed", "stop": add(.slam)
                case "twitter" where words[index].start != linkStart: add(.emphasize)
                case "dark", "hide": add(.invisibleInk)
                case "cheese", "shine", "light": add(.spotlight)
                default: break
                }
            }
            if let written, written.index == index, words[index].start != linkStart,
               !events.contains(where: { $0.kind.isReaction && $0.start == words[index].start }) {
                add(written.kind)
            }
        }
        return events
    }

    /// Pick one written reply per phrase. A question or repeated exclamation only
    /// arrives on the closing word; a pair of sung "ha"s becomes laughter on the second.
    private static func writtenReaction(in words: [StudioWord], tokens: [String]) -> (index: Int, kind: Kind)? {
        guard let last = words.indices.last else { return nil }
        for (index, word) in words.enumerated() {
            if let thumb = word.text.unicodeScalars.first(where: { $0 == "👍" || $0 == "👎" }) {
                return (index, thumb == "👍" ? .thumbUp : .thumbDown)
            }
        }
        for (index, token) in tokens.enumerated() {
            if token.wholeMatch(of: #/(?:ha){2,}/#) != nil ||
                (index > 0 && token == "ha" && tokens[index - 1] == "ha") {
                return (index, .laugh)
            }
        }
        let closing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ")]}\"'”’»）】」』"))
        let ending = words[last].text.trimmingCharacters(in: closing)
        if let mark = ending.last, "?？؟".contains(mark) { return (last, .question) }
        if ending.suffix(2).count == 2, ending.suffix(2).allSatisfy({ $0 == "!" || $0 == "！" }) {
            return (last, .emphasize)
        }
        if words.count <= 2 {
            if tokens.allSatisfy({ ["yes", "yeah", "yep", "yup"].contains($0) }) { return (0, .thumbUp) }
            if tokens.allSatisfy({ ["no", "nah", "nope"].contains($0) }) { return (0, .thumbDown) }
        }
        return nil
    }
}

extension StudioLyricScore.Message {
    nonisolated func reaction(at time: Double) -> StudioLyricEvent? {
        sceneEvents.last { $0.custom && $0.start <= time && $0.kind.isReaction }
            ?? sceneEvents.last { $0.start <= time && $0.kind == .slowSilver }
            ?? sceneEvents.last { $0.start <= time && $0.kind.isReaction }
    }

    nonisolated func bubbleEffect(at time: Double) -> StudioLyricEvent? {
        let available = sceneEvents.filter {
            $0.start <= time && !$0.kind.isReaction && time - $0.start < 1.2 && !($0.custom && $0.kind == .echo)
        }
        return available.last { $0.custom } ?? available.last
    }

    nonisolated func echo(at time: Double) -> StudioLyricEvent? {
        sceneEvents.last { $0.custom && $0.kind == .echo && $0.start <= time && time - $0.start < 1.2 }
            ?? bubbleEffect(at: time).flatMap { $0.kind == .echo ? $0 : nil }
    }
}
