import CoreGraphics
import Foundation
import ImageIO

/// Recovers missing player covers and enhances a matching local Apple Music sleeve.
actor StudioArtworkLookup {
    typealias Fetch = @Sendable (URL) async throws -> Data

    private nonisolated struct Result: Decodable {
        let artistName: String
        let collectionName: String?
        let artworkUrl100: URL?
        let trackName: String?
        let trackTimeMillis: Double?
    }
    private nonisolated struct Search: Decodable { let results: [Result] }
    private struct Entry {
        let key: [String]
        let pixels: [UInt8]
        let image: Data?
    }

    private let fetch: Fetch
    private var recent: [Entry] = []
    private enum CoverKey: Equatable { case catalog(String, String, String, Int), spotify(URL) }
    private var covers: [(key: CoverKey, data: Data)] = []
    private var retryAfter: [String: Date] = [:]

    private nonisolated enum ResponseError: Error {
        case missing, busy(until: Date)
    }

    init(fetch: Fetch? = nil) {
        if let fetch { self.fetch = fetch; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config, delegate: ArtworkRedirects(), delegateQueue: nil)
        self.fetch = { url in
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch response.statusCode {
            case 200: break
            case 404, 410: throw ResponseError.missing
            case 429, 503:
                let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 15
                throw ResponseError.busy(until: .now.addingTimeInterval(delay.isFinite ? max(1, delay) : 15))
            default: throw URLError(.badServerResponse)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let limit = url.host == "itunes.apple.com" ? 1_000_000 : 12_000_000
            guard response.expectedContentLength <= limit,
                  let data = try handle.read(upToCount: limit + 1), data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            return data
        }
    }

    private func data(from url: URL) async throws -> Data {
        let host = url.host ?? ""
        if let until = retryAfter[host], until > .now { throw ResponseError.busy(until: until) }
        do {
            let data = try await fetch(url)
            try Task.checkCancellation()
            return data
        } catch ResponseError.busy(let until) {
            retryAfter[host] = until
            throw ResponseError.busy(until: until)
        }
    }

    func cover(for track: StudioTrack) async throws -> Data? {
        try Task.checkCancellation()
        if let local = track.artworkData, Self.isDecodableArtwork(local) { return local }
        let key: CoverKey
        switch track.source {
        case .spotify:
            guard let url = track.artworkURL, url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            key = .spotify(url)
        case .appleMusic:
            guard track.allowsCatalogArtwork, track.duration.isFinite, (1...86_400).contains(track.duration) else { return nil }
            let title = Self.normalized(track.title), artist = Self.normalized(track.artist), album = Self.normalized(track.album)
            guard !title.isEmpty, !artist.isEmpty, !album.isEmpty else { return nil }
            key = .catalog(title, artist, album, Int(track.duration.rounded()))
        }
        if let index = covers.firstIndex(where: { $0.key == key }) {
            let entry = covers.remove(at: index)
            covers.append(entry)
            return entry.data
        }
        let image: Data?
        switch key {
        case let .spotify(url):
            do {
                let bytes = try await data(from: url)
                image = Self.isDecodableArtwork(bytes) ? bytes : nil
            } catch ResponseError.missing { return nil }
        case let .catalog(title, artist, album, _):
            let results = try await search(artist: track.artist, term: track.title)
            let artwork = Set(results.compactMap { candidate -> URL? in
                guard candidate.trackName.map(Self.normalized) == title,
                      Self.normalized(candidate.artistName) == artist,
                      candidate.collectionName.map(Self.normalized) == album,
                      let ms = candidate.trackTimeMillis, abs(ms / 1000 - track.duration) <= 2,
                      let url = candidate.artworkUrl100, Self.appleImageURL(url) else { return nil }
                return url
            })
            guard artwork.count == 1, let thumbnail = artwork.first else { return nil }
            let urls = [Self.largeArtworkURL(thumbnail, side: 1200), thumbnail].compactMap { $0 }
            var candidate: Data?
            for url in urls {
                do {
                    let bytes = try await data(from: url)
                    if Self.isDecodableArtwork(bytes) { candidate = bytes; break }
                } catch ResponseError.missing { continue }
            }
            image = candidate
        }
        guard let image else { return nil }
        try Task.checkCancellation()
        covers.append((key, image))
        while covers.count > 24 || covers.reduce(0, { $0 + $1.data.count }) > 24_000_000 { covers.removeFirst() }
        return image
    }

    nonisolated static func isDecodableArtwork(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 12_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete, let size = dimensions(data),
              max(size.width, size.height) <= 16_384 else { return false }
        return sample(data) != nil
    }

    func image(artist: String, album: String, original: Data) async throws -> Data? {
        let key = [artist, album].map(Self.normalized)
        guard key.allSatisfy({ !$0.isEmpty }), let size = Self.dimensions(original),
              max(size.width, size.height) <= 1024, let pixels = Self.sample(original) else { return nil }
        if let index = recent.firstIndex(where: { $0.key == key && Self.matches($0.pixels, pixels) }) {
            let entry = recent.remove(at: index)
            recent.append(entry)
            return entry.image
        }
        let results = try await search(artist: artist, term: album)
        var examined = Set<URL>()
        var image: Data?
        for result in results {
            guard Self.normalized(result.artistName) == key[0], result.collectionName.map(Self.normalized) == key[1],
                  let small = result.artworkUrl100, let large = Self.largeArtworkURL(small),
                  examined.insert(small).inserted else { continue }
            guard examined.count <= 3 else { break }
            let thumbnail = try await data(from: small)
            try Task.checkCancellation()
            guard thumbnail.count <= 300_000, let thumbPixels = Self.sample(thumbnail), Self.matches(pixels, thumbPixels) else { continue }
            let candidate = try await data(from: large)
            try Task.checkCancellation()
            guard candidate.count <= 6_000_000, let larger = Self.dimensions(candidate),
                  larger.width >= size.width * 1.35, larger.height >= size.height * 1.35,
                  max(larger.width, larger.height) <= 4096, let largePixels = Self.sample(candidate),
                  Self.matches(pixels, largePixels) else { continue }
            image = candidate
            break
        }
        recent.append(Entry(key: key, pixels: pixels, image: image))
        while recent.count > 12 || recent.reduce(0, { $0 + ($1.image?.count ?? 0) }) > 18_000_000 {
            recent.removeFirst()
        }
        return image
    }

    private func search(artist: String, term: String) async throws -> [Result] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [.init(name: "term", value: artist + " " + term), .init(name: "media", value: "music"),
                                 .init(name: "entity", value: "song"), .init(name: "limit", value: "25")]
        if let country = Locale.current.region?.identifier, country.count == 2 {
            components.queryItems?.append(.init(name: "country", value: country))
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return [] }
        let response = try await data(from: url)
        guard response.count <= 1_000_000 else { return [] }
        return try JSONDecoder().decode(Search.self, from: response).results
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        return folded.replacingOccurrences(of: "’", with: "'").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func appleImageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.hasSuffix(".mzstatic.com") == true &&
            url.port == nil && url.user == nil && url.password == nil
    }

    private static func largeArtworkURL(_ thumb: URL, side: Int = 2400) -> URL? {
        guard appleImageURL(thumb),
              thumb.lastPathComponent.wholeMatch(of: #/[0-9]+x[0-9]+bb\.jpg/#) != nil else { return nil }
        return thumb.deletingLastPathComponent().appendingPathComponent("\(side)x\(side)bb.jpg")
    }

    private nonisolated static func dimensions(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private nonisolated static func sample(_ data: Data) -> [UInt8]? {
        let side = 32
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let ctx = CGContext(data: storage.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func matches(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        var total = 0, outliers = 0
        for i in first.indices {
            let difference = abs(Int(first[i]) - Int(second[i]))
            total += difference
            if difference > 38 { outliers += 1 }
        }
        return total < first.count * 8 && outliers < first.count / 40
    }
}

private nonisolated final class ArtworkRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              let from = task.originalRequest?.url?.host, let to = url.host else { completionHandler(nil); return }
        let apple: (String) -> Bool = { $0 == "itunes.apple.com" || $0.hasSuffix(".mzstatic.com") }
        let spotify: (String) -> Bool = { $0.hasSuffix(".scdn.co") || $0.hasSuffix(".spotifycdn.com") }
        completionHandler(from == to || (apple(from) && apple(to)) || (spotify(from) && spotify(to)) ? request : nil)
    }
}
