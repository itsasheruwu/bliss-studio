import CryptoKit
import Foundation
import Yams

nonisolated struct StudioWord: Codable, Equatable, Sendable {
    let start: Double
    let text: String
    /// Present only when the lyric source marks the end of the sung segment.
    let end: Double?

    init(start: Double, text: String, end: Double? = nil) {
        self.start = start
        self.text = text
        self.end = end.flatMap { $0.isFinite && $0 > start ? $0 : nil }
    }
}

nonisolated struct StudioLine: Codable, Equatable, Sendable {
    let start: Double
    let text: String
    let words: [StudioWord]
    let end: Double?
    private let estimated: Bool?
    var isEstimated: Bool { estimated == true }

    init(start: Double, text: String, words: [StudioWord] = [], end: Double? = nil, estimated: Bool = false) {
        self.start = start
        self.text = text
        self.words = words
        self.end = end
        self.estimated = estimated ? true : nil
    }
}

nonisolated enum StudioLyricsError: LocalizedError, Equatable {
    case noMatch, instrumental, unsynced, invalidFile, serviceUnavailable, rateLimited

    var errorDescription: String? {
        switch self {
        case .noMatch: "No lyrics found for this recording. You can import an LRC or TXT file."
        case .instrumental: "LRCLIB lists this recording as instrumental."
        case .unsynced: "No usable lyrics found. You can import an LRC or TXT file."
        case .invalidFile: "Choose a timed LRC or a plain-text TXT file under 1 MB."
        case .serviceUnavailable: "Couldn’t load lyrics from LRCLIB. Try again later."
        case .rateLimited: "LRCLIB is busy. Try again shortly."
        }
    }
}

actor StudioLyrics {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let imports: URL
    private let cache: URL
    private let request: Request
    private var nextRequestAt = Date.distantPast
    private static let maximumBytes = 1_000_000
    private static let cacheLimit = 48
    private struct PlainImport: Codable {
        let text: String
    }

    init(
        directory: URL = StudioLibrary.directory,
        cache: URL = URL.cachesDirectory.appending(path: "com.itsasheruwu.bliss-studio"),
        request: @escaping Request = { try await URLSession.shared.data(for: $0) }
    ) {
        self.imports = directory.appending(path: "Imported Lyrics")
        self.cache = cache
        self.request = request
    }

    func fetch(for track: StudioTrack) async throws -> [StudioLine] {
        let key = Self.recordingKey(track)
        let imported = imports.appending(path: key)
        if let local = try importedLines(at: imported, duration: track.duration) { return local }

        let cached = cache.appending(path: key)
        let expiry = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        if let date = try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           date > expiry, let data = try? Data(contentsOf: cached),
           let lines = try? Self.decodeRecord(data, duration: track.duration) { return lines }

        guard Date.now >= nextRequestAt else { throw StudioLyricsError.rateLimited }
        do {
            let (data, lines) = try await recording(for: track)
            // An import made while awaiting the provider always wins.
            if let local = try importedLines(at: imported, duration: track.duration) { return local }
            try? cacheRecord(data, at: cached)
            return lines
        } catch {
            try Task.checkCancellation()
            if let local = try importedLines(at: imported, duration: track.duration) { return local }
            throw error
        }
    }

    private func recording(for track: StudioTrack) async throws -> (Data, [StudioLine]) {
        var exactEstimate: (Data, [StudioLine])?
        let original: StudioLyricsError
        do {
            let data = try await recordData(for: track, includeAlbum: true)
            let lines = try Self.decodeRecord(data, duration: track.duration)
            if lines.first?.isEstimated != true { return (data, lines) }
            exactEstimate = (data, lines)
            original = .unsynced
        } catch let error as StudioLyricsError where error == .noMatch || error == .unsynced {
            original = error
        }
        // A compilation may carry a different album name. Prefer verified real
        // timing over an exact album's untimed text; otherwise keep the exact text.
        guard !track.album.isEmpty, (1...3600).contains(track.duration) else {
            if let exactEstimate { return exactEstimate }
            throw original
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            guard Date.now >= nextRequestAt else { throw StudioLyricsError.rateLimited }
            let data = try await recordData(for: track, includeAlbum: false)
            nonisolated struct Identity: Decodable {
                let trackName: String
                let artistName: String
                let duration: Double
            }
            guard let found = try? JSONDecoder().decode(Identity.self, from: data),
                  found.trackName.localizedCaseInsensitiveCompare(track.title) == .orderedSame,
                  found.artistName.localizedCaseInsensitiveCompare(track.artist) == .orderedSame,
                  abs(found.duration - track.duration) <= 2 else { throw original }
            let lines = try Self.decodeRecord(data, duration: track.duration)
            if lines.first?.isEstimated == true, let exactEstimate { return exactEstimate }
            return (data, lines)
        } catch {
            try Task.checkCancellation()
            if let exactEstimate { return exactEstimate }
            if (error as? StudioLyricsError) == .noMatch { throw original }
            throw error
        }
    }

    private func recordData(for track: StudioTrack, includeAlbum: Bool) async throws -> Data {
        let (data, response) = try await request(Self.lyricRequest(for: track, includeAlbum: includeAlbum))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw StudioLyricsError.serviceUnavailable }
        if response.statusCode == 429 || response.statusCode == 503 {
            let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            let delay = retry.isFinite ? max(1, retry) : 5
            nextRequestAt = max(nextRequestAt, Date.now.addingTimeInterval(delay + .random(in: 0...1)))
            throw StudioLyricsError.rateLimited
        }
        if response.statusCode == 404 { throw StudioLyricsError.noMatch }
        guard response.statusCode == 200, data.count <= Self.maximumBytes else {
            throw StudioLyricsError.serviceUnavailable
        }
        return data
    }

    func importFile(_ url: URL, for track: StudioTrack) async throws -> [StudioLine] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Self.maximumBytes + 1),
              data.count <= Self.maximumBytes else { throw StudioLyricsError.invalidFile }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { throw StudioLyricsError.invalidFile }
        let plain = url.pathExtension.lowercased() == "txt"
        let lines = plain ? Self.estimate(text, duration: track.duration) : Self.parseLRC(text)
        guard !lines.isEmpty else { throw StudioLyricsError.invalidFile }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let saved = plain ? try JSONEncoder().encode(PlainImport(text: text)) : Data(text.utf8)
        try saved.write(to: imports.appending(path: Self.recordingKey(track)), options: .atomic)
        return lines
    }

    private func importedLines(at url: URL, duration: Double) throws -> [StudioLine]? {
        do {
            let data = try Data(contentsOf: url)
            if data.first == 0x7B, let plain = try? JSONDecoder().decode(PlainImport.self, from: data) {
                return Self.estimate(plain.text, duration: duration)
            }
            // Earlier versions saved the original LRC directly under this key.
            return Self.parseLRC(String(decoding: data, as: UTF8.self))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func cacheRecord(_ data: Data, at url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let entries = try files.contentsOfDirectory(at: cache, includingPropertiesForKeys: Array(keys),
                                                    options: [.skipsHiddenFiles])
        guard entries.count > Self.cacheLimit else { return }
        let sorted = entries.sorted {
            let first = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let second = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (first ?? .distantPast) > (second ?? .distantPast)
        }
        for old in sorted.dropFirst(Self.cacheLimit) { try? files.removeItem(at: old) }
    }

    nonisolated static func recordingKey(_ track: StudioTrack) -> String {
        // A source's stable item ID distinguishes versions and survives changes in playback position.
        let signature = [track.source.rawValue, track.id, track.title, track.artist, track.album]
        let bytes = (try? JSONEncoder().encode(signature)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func lyricRequest(for track: StudioTrack, includeAlbum: Bool) throws -> URLRequest {
        guard !track.title.isEmpty, !track.artist.isEmpty else { throw StudioLyricsError.noMatch }
        var query = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if includeAlbum, !track.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: track.album)) }
        if (1...3600).contains(track.duration) {
            query.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        components.queryItems = query
        // A literal '+' is legal in URLs but many query parsers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw StudioLyricsError.noMatch }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("BlissStudio v1.0 (https://github.com/itsasheruwu/bliss-studio)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func decodeRecord(_ data: Data, duration: Double) throws -> [StudioLine] {
        nonisolated struct Record: Decodable {
            let instrumental: Bool
            let hasWordSync: Bool?
            let lyricsfile: String?
            let syncedLyrics: String?
            let plainLyrics: String?
        }
        guard data.count <= maximumBytes, let record = try? JSONDecoder().decode(Record.self, from: data)
        else { throw StudioLyricsError.serviceUnavailable }
        if record.instrumental { throw StudioLyricsError.instrumental }
        if let yaml = record.lyricsfile, record.hasWordSync == true || record.syncedLyrics == nil,
           let document = try? YAMLDecoder().decode(Lyricsfile.self, from: yaml) {
            let lines = document.timedLines
            if !lines.isEmpty { return lines }
        }
        let timed = parseLRC(record.syncedLyrics ?? "")
        if !timed.isEmpty { return timed }
        let estimated = estimate(record.plainLyrics ?? "", duration: duration)
        guard !estimated.isEmpty else { throw StudioLyricsError.unsynced }
        return estimated
    }

    private nonisolated struct Lyricsfile: Decodable {
        struct Segment: Decodable {
            let text: String
            let start_ms: Int
            let end_ms: Int?
        }
        struct Line: Decodable {
            let text: String
            let start_ms: Int
            let end_ms: Int?
            let words: [Segment]?
        }
        let lines: [Line]
        var timedLines: [StudioLine] {
            lines.compactMap { line in
                guard line.start_ms >= 0, !line.text.isEmpty else { return nil }
                let segments = line.words ?? []
                let valid = segments.allSatisfy { $0.start_ms >= 0 }
                    && segments.map(\.text).joined() == line.text
                let words = valid ? segments.map { segment in
                    StudioWord(start: Double(segment.start_ms) / 1000, text: segment.text,
                                   end: segment.end_ms.map { Double($0) / 1000 })
                } : []
                let end = line.end_ms.flatMap { $0 >= line.start_ms ? Double($0) / 1000 : nil }
                return StudioLine(start: Double(line.start_ms) / 1000, text: line.text, words: words, end: end ?? words.last?.end)
            }.sorted { $0.start < $1.start }
        }
    }

    /// Distribute untimed lines across the recording. Blank rows reserve time
    /// between stanzas. These lines carry no observed word boundaries.
    nonisolated static func estimate(_ text: String, duration: Double) -> [StudioLine] {
        let rows = text.trimmingPrefix("\u{feff}").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !rows.isEmpty, rows.count <= 20_000 else { return [] }
        let weights = rows.map { row in
            let tokens = row.split(whereSeparator: \.isWhitespace)
            let length = tokens.reduce(0) { $0 + $1.count }
            // Character weight also works for scripts without word separators.
            return tokens.isEmpty ? 2.0 : max(2.0, Double(tokens.count), Double(length) / 4.0)
        }
        let total = weights.reduce(0, +)
        let secondsPerUnit = duration.isFinite && duration > 0 ? duration / total : 0.42
        var position = 0.0
        var lines: [StudioLine] = []
        for (row, weight) in zip(rows, weights) {
            let start = position
            position += weight * secondsPerUnit
            if !row.allSatisfy(\.isWhitespace) {
                lines.append(.init(start: start, text: String(row), end: position, estimated: true))
            }
        }
        return lines
    }

    nonisolated static func parseLRC(_ source: String) -> [StudioLine] {
        let rows = source.trimmingPrefix("\u{feff}").split(whereSeparator: \.isNewline)
        // Positive LRC offsets display the lyrics earlier. Metadata may follow the lyrics.
        var offset = 0.0
        for row in rows {
            if let tag = row.wholeMatch(of: #/\s*\[(?i:offset):\s*([+-]?[0-9]+)\s*\]\s*/#),
               let milliseconds = Int(tag.1) { offset = Double(milliseconds) / 1000 }
        }
        var lines: [StudioLine] = []
        var gaps: [Double] = []
        var expandedWordCount = 0
        for row in rows {
            var content = row.trimmingCharacters(in: .whitespaces)[...]
            var starts: [Double] = []
            while let stamp = content.prefixMatch(of: #/\[([0-9]{1,4}):([0-5][0-9](?:[.,][0-9]{1,3})?)\]\s*/#) {
                starts.append(timestamp(minutes: stamp.1, seconds: stamp.2))
                content = content[stamp.range.upperBound...]
            }
            guard let first = starts.first else { continue }
            let (text, words) = enhancedText(content, lineStart: first)
            if text.isEmpty { gaps.append(contentsOf: starts.map { max(0, $0 - offset) }); continue }
            // Repeated line timestamps duplicate the entire word timeline.
            expandedWordCount += starts.count * words.count
            guard expandedWordCount <= 100_000, lines.count + starts.count <= 20_000 else { return [] }
            for start in starts {
                let shift = start - first - offset
                let timed = words.map { word in
                    StudioWord(start: max(0, word.start + shift), text: word.text, end: word.end.map { max(0, $0 + shift) })
                }
                lines.append(.init(start: max(0, start - offset), text: text, words: timed, end: timed.last?.end))
            }
        }
        let ordered = lines.sorted { $0.start < $1.start }
        let breaks = gaps.sorted()
        var nextBreak = 0
        return ordered.enumerated().map { index, line in
            while nextBreak < breaks.count, breaks[nextBreak] <= line.start { nextBreak += 1 }
            let nextStart = index + 1 < ordered.count ? ordered[index + 1].start : .infinity
            guard nextBreak < breaks.count, breaks[nextBreak] < nextStart else { return line }
            return StudioLine(start: line.start, text: line.text, words: line.words, end: min(line.end ?? .infinity, breaks[nextBreak]))
        }
    }

    private nonisolated static func timestamp(minutes: Substring, seconds: Substring) -> Double {
        (Double(minutes) ?? 0) * 60 + (Double(seconds.replacingOccurrences(of: ",", with: ".")) ?? 0)
    }

    private nonisolated static func enhancedText(_ text: Substring, lineStart: Double) -> (String, [StudioWord]) {
        let stamps = text.matches(of: #/<([0-9]{1,4}):([0-5][0-9](?:[.,][0-9]{1,3})?)>/#)
        guard let first = stamps.first else { return (String(text), []) }
        var segments: [StudioWord] = []
        let prefix = text[..<first.range.lowerBound]
        if !prefix.isEmpty { segments.append(.init(start: lineStart, text: String(prefix))) }
        for (index, stamp) in stamps.enumerated() {
            let end = index + 1 < stamps.count ? stamps[index + 1].range.lowerBound : text.endIndex
            let word = text[stamp.range.upperBound..<end]
            if !word.isEmpty {
                segments.append(.init(start: timestamp(minutes: stamp.1, seconds: stamp.2), text: String(word)))
            } else if let previous = segments.last, previous.end == nil {
                // An empty enhanced-LRC marker closes the previous word, even if
                // the following vocal starts much later.
                segments[segments.count - 1] = .init(start: previous.start, text: previous.text,
                                                     end: timestamp(minutes: stamp.1, seconds: stamp.2))
            }
        }
        let fullLine = segments.map(\.text).joined()
        guard !fullLine.trimmingCharacters(in: .whitespaces).isEmpty else { return ("", []) }
        return (fullLine, segments)
    }
}
