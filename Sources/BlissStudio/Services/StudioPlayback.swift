import AppKit
import Carbon

nonisolated enum StudioSource: String, CaseIterable, Identifiable, Sendable {
    case spotify
    case appleMusic

    var id: Self { self }
    var title: String { self == .spotify ? "Spotify" : "Apple Music" }
    var bundleIdentifier: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
}

nonisolated enum StudioCommand: Equatable, Sendable {
    case playPause, previous, next
    case seek(Double)
}

nonisolated struct StudioTrack: Sendable {
    let id: String
    let source: StudioSource
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let isPlaying: Bool
    let sampledAt: Date
    let artworkURL: URL?
    let artworkData: Data?
    var tempo: Double? = nil
    var allowsCatalogArtwork = false

    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(sampledAt)) : 0
        let result = max(0, position + elapsed)
        return duration > 0 ? min(duration, result) : result
    }
}

/// Music may publish the cover after the track title; Spotify can rotate a CDN URL
/// while the song remains selected. Missing metadata is re-read with a bounded backoff.
nonisolated struct StudioArtworkProbe {
    private var id: String?
    private var next = Date.distantPast
    private var delay = 2.0

    func isDue(for track: String, at time: Date) -> Bool { id != track || time >= next }

    mutating func record(track: String, at time: Date, complete: Bool, refreshURL: Bool) {
        if id != track { delay = 2 }
        id = track
        if complete {
            delay = 2
            next = refreshURL ? time.addingTimeInterval(60) : .distantFuture
        } else {
            next = time.addingTimeInterval(delay)
            delay = min(30, delay * 2)
        }
    }
}

nonisolated enum StudioPlaybackError: LocalizedError, Equatable {
    case needsAccess(StudioSource)
    case accessDenied(StudioSource)
    case playerClosed(StudioSource)
    case unavailable(StudioSource, Int)

    var errorDescription: String? {
        switch self {
        case .needsAccess(let source):
            "Connect \(source.title) to let Bliss Studio follow your playback."
        case .accessDenied(let source):
            "Allow Bliss Studio to control \(source.title) in System Settings → Privacy & Security → Automation."
        case .playerClosed(let source):
            "\(source.title) is closed."
        case .unavailable(let source, _):
            "\(source.title) couldn’t complete the playback request."
        }
    }
}

/// Apple events run on this actor, off the UI thread, addressed to the player's
/// live process. A player quitting between discovery and delivery cannot be relaunched.
actor StudioPlayback {
    private var lastSource: StudioSource?
    private var cached: [StudioSource: StudioTrack] = [:]
    private var artworkProbes: [StudioSource: StudioArtworkProbe] = [:]

    func read(preferred: StudioSource? = nil, requestAccess: Bool = false) throws -> StudioTrack? {
        var sources = preferred.map { [$0] } ?? StudioSource.allCases
        if preferred == nil, let lastSource {
            sources = [lastSource] + sources.filter { $0 != lastSource }
        } else if preferred == nil, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  let active = sources.first(where: { $0.bundleIdentifier == front }) {
            sources = [active] + sources.filter { $0 != active }
        }

        let track = try Self.choose(sources, requestAccess: requestAccess) { source, connect in
            guard let player = StudioAppleEvents(source) else {
                cached[source] = nil
                artworkProbes[source] = nil
                return nil
            }
            if connect { try player.requestAccess() }
            return try snapshot(player)
        }
        if let track { lastSource = track.source }
        return track
    }

    // Probe available players first so a working source never requires consent
    // for a different app. Connect can prompt for at most one running player.
    nonisolated static func choose(_ sources: [StudioSource], requestAccess: Bool,
                                   read: (StudioSource, Bool) throws -> StudioTrack?) throws -> StudioTrack? {
        var paused: StudioTrack?
        var needsAccess: StudioSource?
        var failure: StudioPlaybackError?
        for source in sources {
            do {
                if let track = try read(source, false) {
                    if track.isPlaying { return track }
                    if paused == nil { paused = track }
                }
            } catch StudioPlaybackError.needsAccess(let source) {
                if needsAccess == nil { needsAccess = source }
            } catch StudioPlaybackError.playerClosed {
                continue
            } catch let error as StudioPlaybackError {
                if failure == nil { failure = error }
            }
        }
        if let paused { return paused }
        if let needsAccess {
            guard requestAccess else { throw StudioPlaybackError.needsAccess(needsAccess) }
            return try read(needsAccess, true)
        }
        if let failure { throw failure }
        return nil
    }

    func send(_ command: StudioCommand, to source: StudioSource) throws {
        guard let player = StudioAppleEvents(source) else {
            throw StudioPlaybackError.playerClosed(source)
        }
        try player.send(command)
    }

    private func snapshot(_ player: StudioAppleEvents) throws -> StudioTrack? {
        let source = player.source
        let state = try player.property("pPlS").enumCodeValue
        guard state == fourCC("kPSP") || state == fourCC("kPSp") else { return nil }
        let current = StudioAppleEvents.propertyReference("pTrk")
        // Library tracks have stable IDs. Streams can return no ID, or the same
        // placeholder ID across tracks, so include the display name in the key.
        guard let title = try player.optionalProperty("pnam", of: current)?.stringValue,
              !title.isEmpty else { return nil }
        let trackID = try player.optionalProperty(source == .spotify ? "ID  " : "pPIS", of: current)?.stringValue
        let artist = try player.optionalProperty("pArt", of: current)?.stringValue ?? ""
        let id = [source.rawValue, trackID ?? "", title, artist].joined(separator: "\u{1F}")
        let position = try player.property("pPos").doubleValue
        let sampledAt = Date()
        let metadata = cached[source].flatMap { $0.id == id ? $0 : nil }
        var album = metadata?.album ?? ""
        var duration = metadata?.duration ?? 0
        var artworkURL = metadata?.artworkURL
        var artworkData = metadata?.artworkData
        var tempo = metadata?.tempo
        var allowsCatalogArtwork = metadata?.allowsCatalogArtwork ?? false
        var probe = artworkProbes[source] ?? StudioArtworkProbe()
        if metadata == nil || probe.isDue(for: id, at: sampledAt) {
            if album.isEmpty { album = (try? player.optionalProperty("pAlb", of: current))?.stringValue ?? "" }
            if duration <= 0 {
                let raw = (try? player.optionalProperty("pDur", of: current))?.doubleValue ?? 0
                // Spotify's desktop scripting implementation returns milliseconds.
                duration = max(0, source == .spotify ? raw / 1_000 : raw)
            }
            switch source {
            case .spotify:
                if let value = (try? player.optionalProperty("aUrl", of: current))?.stringValue,
                   let url = URL(string: value), url.scheme?.lowercased() == "https" { artworkURL = url }
            case .appleMusic:
                if metadata == nil { tempo = (try? player.optionalProperty("pBPM", of: current))?.doubleValue }
                if artworkData == nil {
                    let art = StudioAppleEvents.firstArtwork(of: current)
                    for property: StaticString in ["pRaw", "pPCT"] {
                        if let bytes = (try? player.optionalProperty(property, of: art))?.data,
                           StudioArtworkLookup.isDecodableArtwork(bytes) { artworkData = bytes; break }
                    }
                    if artworkData == nil && !allowsCatalogArtwork {
                        allowsCatalogArtwork = player.canRecoverCatalogArtwork(for: current)
                    }
                }
            }
            // Each Apple event addresses current track. A track switch between these
            // calls must not associate the next song's cover with the previous ID.
            let verifiedTitle = try player.optionalProperty("pnam", of: current)?.stringValue
            let verifiedID = try player.optionalProperty(source == .spotify ? "ID  " : "pPIS", of: current)?.stringValue
            let verifiedArtist = try player.optionalProperty("pArt", of: current)?.stringValue ?? ""
            guard verifiedTitle == title, verifiedID == trackID, verifiedArtist == artist else { return nil }
            probe.record(track: id, at: sampledAt, complete: (artworkURL != nil || artworkData != nil) && !album.isEmpty && duration > 0,
                         refreshURL: source == .spotify)
            artworkProbes[source] = probe
        }

        let track = StudioTrack(id: id, source: source, title: title, artist: artist, album: album,
                                   duration: duration, position: max(0, position), isPlaying: state == fourCC("kPSP"),
                                   sampledAt: sampledAt, artworkURL: artworkURL, artworkData: artworkData, tempo: tempo,
                                   allowsCatalogArtwork: allowsCatalogArtwork)
        cached[source] = track
        return track
    }
}

/// The suite and property codes come from the players' installed scripting
/// dictionaries (Spotify.sdef and com.apple.Music.sdef).
nonisolated private func fourCC(_ string: StaticString) -> UInt32 {
    string.withUTF8Buffer { bytes in
        precondition(bytes.count == 4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

nonisolated private struct StudioAppleEvents {
    let source: StudioSource
    let target: NSAppleEventDescriptor

    init?(_ source: StudioSource) {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier)
            .first(where: { !$0.isTerminated }) else { return nil }
        self.source = source
        self.target = NSAppleEventDescriptor(processIdentifier: process.processIdentifier)
    }

    func requestAccess() throws {
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, UInt32(typeWildCard), UInt32(typeWildCard), true)
        if status != noErr { throw error(code: Int(status)) }
    }

    func canRecoverCatalogArtwork(for current: NSAppleEventDescriptor) -> Bool {
        do {
            let status = try optionalProperty("pClS", of: current)?.enumCodeValue
            if let status, status != fourCC("kUnk") {
                return [fourCC("kSub"), fourCC("kPur"), fourCC("kMat"), fourCC("kPrR")].contains(status)
            }
            guard try optionalProperty("pcls", of: current)?.typeCodeValue == fourCC("cURT") else { return false }
            // Music supplies an opaque URL track with no address for catalog streams.
            // A user-added online radio feed exposes its custom address.
            guard let address = try optionalProperty("pURL", of: current)?.stringValue, !address.isEmpty else { return true }
            let host = URL(string: address)?.host?.lowercased() ?? ""
            return host == "music.apple.com" || host == "itunes.apple.com" || host.hasSuffix(".mzstatic.com")
        } catch { return false }
    }

    func send(_ command: StudioCommand) throws {
        let suite = source == .spotify ? fourCC("spfy") : fourCC("hook")
        switch command {
        case .playPause: _ = try event(suite, fourCC("PlPs"))
        case .previous: _ = try event(suite, fourCC("Prev"))
        case .next: _ = try event(suite, fourCC("Next"))
        case .seek(let position):
            guard position.isFinite else { return }
            _ = try event(fourCC("core"), fourCC("setd"), object: Self.propertyReference("pPos"),
                          value: NSAppleEventDescriptor(double: max(0, position)))
        }
    }

    func property(_ name: StaticString, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try event(fourCC("core"), fourCC("getd"), object: Self.propertyReference(name, of: container))
    }

    func optionalProperty(_ name: StaticString, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do {
            let value = try property(name, of: container)
            if value.descriptorType == typeNull || (value.descriptorType == typeType && value.typeCodeValue == fourCC("msng")) {
                return nil
            }
            return value
        } catch StudioPlaybackError.unavailable(_, let code) where [-1728, -1708, -10000, -1721].contains(code) {
            // Either no track/artwork exists, or this track type doesn't expose the property.
            return nil
        }
    }

    static func propertyReference(_ name: StaticString, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        reference(want: fourCC("prop"), form: fourCC("prop"), key: .init(typeCode: fourCC(name)), of: container)
    }

    static func firstArtwork(of track: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        reference(want: fourCC("cArt"), form: fourCC("indx"), key: .init(int32: 1), of: track)
    }

    private static func reference(want: UInt32, form: UInt32, key: NSAppleEventDescriptor,
                                  of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        // An object specifier is an AE record with the type 'obj '.
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: want), forKeyword: fourCC("want"))
        record.setDescriptor(.init(enumCode: form), forKeyword: fourCC("form"))
        record.setDescriptor(key, forKeyword: fourCC("seld"))
        record.setDescriptor(container, forKeyword: fourCC("from"))
        return record.coerce(toDescriptorType: fourCC("obj "))!
    }

    @discardableResult
    private func event(_ suite: UInt32, _ id: UInt32, object: NSAppleEventDescriptor? = nil,
                       value: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let request = NSAppleEventDescriptor(eventClass: suite, eventID: id, targetDescriptor: target,
                                             returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID))
        if let object { request.setParam(object, forKeyword: keyDirectObject) }
        if let value { request.setParam(value, forKeyword: keyAEData) }
        // Permission can change even after preflight. Never let an ordinary poll
        // or transport event cause a system consent prompt.
        let noPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
        let reply: NSAppleEventDescriptor
        do {
            reply = try request.sendEvent(options: [.waitForReply, .neverInteract, noPrompt], timeout: 1.5)
        } catch let failure as NSError {
            throw error(code: failure.code)
        }
        if let status = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, status != 0 {
            throw error(code: Int(status))
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    private func error(code: Int) -> StudioPlaybackError {
        switch code {
        case Int(errAEEventWouldRequireUserConsent): .needsAccess(source)
        case Int(errAEEventNotPermitted): .accessDenied(source)
        case Int(procNotFound), Int(connectionInvalid): .playerClosed(source)
        default: .unavailable(source, code)
        }
    }
}
