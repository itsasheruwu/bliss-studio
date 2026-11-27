import Foundation

nonisolated struct StudioWordAccent: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case big, small, shake, nod, explode, ripple, bloom, jitter
    }

    let kind: Kind
    let duration: Double
    let strength: Double
}

/// Scores timing and text once per vocal phrase. Rendering can replay any moment
/// from the player's clock, including when importing a line-only LRC or seeking.
nonisolated struct StudioVocalPhrasing {
    private let secondsPerSyllable: Double
    private var phrases: Set<[String]> = []
    private var recentEndings: [String] = []

    init(lines: [StudioLine]) {
        // A held note in a fast verse can be shorter than an ordinary word in a
        // ballad. Work relative to the recording's typical pace.
        var intervals: [Double] = []
        for line in lines {
            for (word, following) in zip(line.words, line.words.dropFirst()) {
                let interval = (word.end ?? following.start) - word.start
                guard (0.05...1.35).contains(interval) else { continue }
                intervals.append(interval / Double(Self.syllables(in: word.text)))
            }
        }
        intervals.sort()
        secondsPerSyllable = intervals.isEmpty ? 0.24 : min(0.48, max(0.10, intervals[intervals.count / 2]))
    }

    private struct Candidate {
        let kind: StudioWordAccent.Kind
        let priority: Double
    }

    mutating func accents(words: [StudioWord], keys: [String], lineEnd: Double?, timed: Bool) -> [StudioWordAccent?] {
        guard !words.isEmpty else { return [] }
        let refrain = keys.count > 1 && !phrases.insert(keys).inserted
        let last = words.count - 1
        let finalWord = keys[last]
        let rhyme = Self.rhymeEnding(finalWord)
        let rhymed = rhyme != nil && recentEndings.contains { $0 != finalWord && Self.rhymeEnding($0) == rhyme }
        recentEndings.append(finalWord)
        if recentEndings.count > 2 { recentEndings.removeFirst() }

        var candidates: [(index: Int, accent: StudioWordAccent, priority: Double)] = []
        for (i, word) in words.enumerated() {
            let key = keys[i]
            guard key.contains(where: { $0.isLetter || $0.isNumber || $0.isSymbol }) else { continue }
            let syllables = Double(Self.syllables(in: key))
            let expected = secondsPerSyllable * syllables
            let next = i < last ? words[i + 1].start : nil
            let markedEnd = word.end ?? (i == last ? lineEnd : nil)
            let interval = max(0, (markedEnd ?? next ?? word.start) - word.start)
            // A gap until the next line is never evidence of a sustained vowel.
            // Within a line a large onset-to-onset gap may also be a breath.
            let credible = markedEnd != nil || (next != nil && interval <= min(1.7, max(0.9, expected * 4)))
            let held = timed && credible && interval >= max(0.55, expected * 1.7)
            let repeated = i > 0 && keys[i - 1] == key
            let spacing = i > 0 ? word.start - words[i - 1].start : .infinity
            let staccato = timed && next != nil && interval > 0 && interval < min(0.22, expected * 0.85) &&
                spacing < 0.24 && i > 0
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = key.filter(\.isLetter)
            let caps = letters.count > 1 && trimmed.contains(where: \.isUppercase) && !trimmed.contains(where: \.isLowercase)
            var choices: [Candidate] = []
            if Self.isStutter(key) || (repeated && timed && spacing < 0.225) {
                choices.append(.init(kind: .jitter, priority: 1.12))
            } else if repeated {
                choices.append(.init(kind: .nod, priority: 0.94))
            }
            if let meaning = Self.wordEffect(key) {
                choices.append(.init(kind: meaning, priority: 1.0))
            }
            if held {
                choices.append(.init(kind: .bloom, priority: min(1.09, 0.84 + (interval / expected - 1.7) * 0.09)))
            }
            if staccato { choices.append(.init(kind: .nod, priority: 0.73)) }
            if trimmed.contains("!") || trimmed.contains("！") || caps {
                choices.append(.init(kind: .big, priority: 0.95))
            } else if trimmed.contains("?") || trimmed.contains("？") || trimmed.contains("؟") {
                choices.append(.init(kind: .ripple, priority: 0.91))
            } else if trimmed.hasSuffix("…") || trimmed.hasSuffix("...") {
                choices.append(.init(kind: .small, priority: 0.90))
            }
            if i == last, rhymed { choices.append(.init(kind: .ripple, priority: 0.77)) }
            if i == 0, refrain { choices.append(.init(kind: .big, priority: 0.86)) }
            // Even an unfamiliar language with only line timestamps gets a
            // gentle stress on a substantive word. Measured delivery wins.
            let stress = min(0.55, 0.22 + 0.065 * syllables + min(0.13, Double(letters.count) * 0.012))
            choices.append(.init(kind: .nod, priority: stress))
            guard let best = choices.max(by: { $0.priority < $1.priority }) else { continue }

            let span: Double
            switch best.kind {
            case .bloom, .ripple:
                span = min(1.65, max(0.46, timed && credible ? interval : 0.65))
            case .jitter, .nod:
                span = min(0.42, max(0.18, timed && credible ? interval : 0.28))
            case .big, .small, .shake, .explode:
                span = min(0.82, max(0.38, timed && credible ? interval : 0.5))
            }
            let strength = min(1, best.priority * (timed ? 1 : 0.86))
            candidates.append((i, .init(kind: best.kind, duration: span, strength: strength), best.priority))
        }

        var result = [StudioWordAccent?](repeating: nil, count: words.count)
        let budget = min(4, max(1, (words.count + 2) / 4))
        let ranked = candidates.sorted { $0.priority == $1.priority ? $0.index < $1.index : $0.priority > $1.priority }
        var selected: [Double] = []
        for candidate in ranked {
            if selected.count >= budget { break }
            if candidate.priority < 0.6, !selected.isEmpty { break }
            let start = words[candidate.index].start
            guard selected.allSatisfy({ abs($0 - start) >= 0.30 }) else { continue }
            result[candidate.index] = candidate.accent
            selected.append(start)
        }
        return result
    }

    private static func syllables(in token: String) -> Int {
        let letters = token.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter)
        let vowels = "aeiouy"
        var groups = 0
        var inVowel = false
        for letter in letters {
            let vowel = vowels.contains(letter)
            if vowel && !inVowel { groups += 1 }
            inVowel = vowel
        }
        if groups > 1, letters.hasSuffix("e"), !letters.hasSuffix("le") { groups -= 1 }
        if groups > 0 { return groups }
        return min(5, max(1, letters.count / 3))
    }

    private static func rhymeEnding(_ token: String) -> String? {
        // Restrict this optional cue to unambiguous written endings. Cadence
        // and repetition continue to work across scripts.
        guard token.count >= 3, token.allSatisfy({ $0.isASCII && $0.isLetter }),
              let lastVowel = token.lastIndex(where: { "aeiouy".contains($0) }) else { return nil }
        var from = lastVowel
        while from > token.startIndex, "aeiouy".contains(token[token.index(before: from)]) {
            from = token.index(before: from)
        }
        let ending = String(token[from...])
        guard ending.count >= 2, !["ing", "er", "ed", "es", "en"].contains(ending) else { return nil }
        return ending
    }

    private static func isStutter(_ token: String) -> Bool {
        let parts = token.split(whereSeparator: { $0 == "-" || $0 == "‐" || $0 == "‑" })
        guard parts.count >= 2, let first = parts.first, first.count <= 2, let last = parts.last else { return false }
        return last.hasPrefix(first) && parts.dropLast().allSatisfy { $0 == first }
    }

    private static func wordEffect(_ token: String) -> StudioWordAccent.Kind? {
        switch token {
        case "shout", "shouting", "louder", "roar", "roaring", "scream", "screaming", "rise", "rising": .big
        case "whisper", "whispering", "quiet", "quietly", "hush", "hushed", "tiny", "silence", "fading": .small
        case "shake", "shaking", "shiver", "shivering", "tremble", "trembling", "thunder", "thundering": .shake
        case "boom", "bang", "burst", "explode", "exploding", "crash", "crashing", "shatter", "shattering": .explode
        case "wave", "waves", "ripple", "ripples", "echo", "echoes", "ocean", "water", "flow", "flowing": .ripple
        case "bloom", "blooming", "shine", "shining", "glow", "glowing", "float", "floating": .bloom
        case "flicker", "flickering", "stutter", "stuttering", "twitch", "twitching": .jitter
        case "bounce", "bouncing", "knock", "knocking", "heartbeat": .nod
        default: nil
        }
    }
}
