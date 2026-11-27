import AppKit
import BlissAudio
import Observation
import UniformTypeIdentifiers

enum StudioPaletteMode: String, CaseIterable {
    case artwork = "Album artwork"
    case dusk = "Dusk"
    case tide = "Tide"
    case ember = "Ember"
}

@Observable
final class StudioSession {
    private(set) var track: StudioTrack?
    private(set) var artwork: NSImage?
    private(set) var lyrics: [StudioLine] = []
    private(set) var lyricsStatus = ""
    private(set) var lyricEffects: StudioEffectsGraph?
    private(set) var playerStatus = "Open Spotify or Apple Music and play a song."
    private(set) var meterStatus: String?
    private(set) var isPreview = false
    var hasLivePlayback: Bool { !isPreview && track?.isPlaying == true }
    var desktopLightEnabled: Bool {
        didSet { defaults.set(desktopLightEnabled, forKey: "studio.desktop") }
    }

    var preferredSource: StudioSource? {
        didSet {
            defaults.set(preferredSource?.rawValue, forKey: "studio.player")
            if active && !isPreview {
                apply(nil)
                followPlayer()
            }
        }
    }
    var showLyrics: Bool {
        didSet {
            defaults.set(showLyrics, forKey: "studio.showLyrics")
            if showLyrics && wantsContent && !isPreview && lyrics.isEmpty { retryLyrics() }
        }
    }
    var lyricOffset = 0.0
    var animateLight: Bool {
        didSet {
            guard animateLight != oldValue else { return }
            rimMotion.pause()
            defaults.set(animateLight, forKey: "studio.animate")
        }
    }
    var paletteMode: StudioPaletteMode {
        didSet { defaults.set(paletteMode.rawValue, forKey: "studio.palette") }
    }
    var lightWidth: Double {
        didSet { defaults.set(lightWidth, forKey: "studio.width") }
    }
    var lightIntensity: Double {
        didSet { defaults.set(lightIntensity, forKey: "studio.glow") }
    }
    var reactive: Bool {
        didSet {
            defaults.set(reactive, forKey: "studio.reactive")
            updateMeter()
        }
    }
    var beatSync: Bool {
        didSet {
            defaults.set(beatSync, forKey: "studio.beatSync")
            updateMeter()
        }
    }
    var audioBeat: Double { beatSync && active && !isPreview && track?.isPlaying != false ? meter.beat : 0 }
    var performanceAccent: Double {
        guard reactive || beatSync, active, !isPreview, track?.isPlaying == true else { return 0 }
        return min(1, 0.75 * meter.pulse + 0.25 * meter.level)
    }
    var beatStatus: String {
        if beatSync, let meterStatus { return meterStatus }
        if beatSync, let bpm = lightTempo {
            return "Following the beat at about " + String(Int(bpm.rounded())) + " BPM"
        }
        return "Follow percussion playing on this Mac. Uses system audio access."
    }
    private var lightTempo: Double? {
        guard active, !isPreview, track?.isPlaying != false else { return nil }
        let measured = beatSync ? StudioRimMotion.validTempo(meter.tempo) : nil
        return measured ?? StudioRimMotion.validTempo(track?.tempo)
    }

    func rimPhase(moving: Bool) -> Double {
        rimMotion.sample(at: ProcessInfo.processInfo.systemUptime, tempo: lightTempo, moving: moving, beat: audioBeat)
    }

    var audioLevel: Double { reactive && active && !isPreview ? meter.level : 0 }
    var audioPulse: Double { reactive && active && !isPreview ? meter.pulse : 0 }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let effectsStore = StudioEffectsStore()
    @ObservationIgnored private let playback = StudioPlayback()
    @ObservationIgnored private let library = StudioLyrics()
    @ObservationIgnored private let artworkLookup: StudioArtworkLookup
    @ObservationIgnored private let meter = StudioMeter()
    @ObservationIgnored private var rimMotion = StudioRimMotion()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var lyricLoad: Task<Void, Never>?
    @ObservationIgnored private var artworkLoad: Task<Void, Never>?
    @ObservationIgnored private var needsCover = false
    @ObservationIgnored private var nextCoverAttempt = Date.distantPast
    @ObservationIgnored private var coverRetryDelay = 2.0
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var wantsContent = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previewIndex = 0

    init(defaults: UserDefaults = .standard, artworkLookup: StudioArtworkLookup = StudioArtworkLookup()) {
        self.defaults = defaults
        self.artworkLookup = artworkLookup
        desktopLightEnabled = defaults.bool(forKey: "studio.desktop")
        preferredSource = defaults.string(forKey: "studio.player").flatMap(StudioSource.init)
        showLyrics = defaults.bool(forKey: "studio.showLyrics")
        paletteMode = defaults.string(forKey: "studio.palette").flatMap(StudioPaletteMode.init) ?? .artwork
        lightWidth = min(16, max(1, defaults.object(forKey: "studio.width") as? Double ?? 7))
        lightIntensity = min(1, max(0, defaults.object(forKey: "studio.glow") as? Double ?? 0.78))
        reactive = defaults.bool(forKey: "studio.reactive")
        beatSync = defaults.bool(forKey: "studio.beatSync")
        animateLight = defaults.object(forKey: "studio.animate") as? Bool ?? true
    }

    /// Metadata is needed for desktop lighting. Lyrics are fetched only when a
    /// listening window actually shows them.
    func setPresentation(active: Bool, showsContent: Bool) {
        let previouslyActive = self.active
        let previouslyContent = wantsContent
        self.active = active
        wantsContent = showsContent
        if !active {
            generation += 1
            poll?.cancel()
            commandTask?.cancel()
            isPreview = false
            apply(nil)
        } else if !previouslyActive && !isPreview {
            followPlayer()
        } else if showsContent && !previouslyContent && showLyrics && lyrics.isEmpty && !isPreview {
            retryLyrics()
        }
        if active != previouslyActive { updateMeter() }
    }

    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        if isPreview && track.isPlaying {
            return (track.position + max(0, date.timeIntervalSince(track.sampledAt)))
                .truncatingRemainder(dividingBy: track.duration)
        }
        return track.position(at: date)
    }

    func connect() { followPlayer(askForAccess: true) }
    func endPreview() { followPlayer() }

    private func followPlayer(askForAccess: Bool = false) {
        generation += 1
        commandTask?.cancel()
        let leavingPreview = isPreview
        isPreview = false
        if leavingPreview { apply(nil); updateMeter() }
        restartPolling(askForAccess: askForAccess)
    }

    private func restartPolling(askForAccess: Bool = false) {
        poll?.cancel()
        let source = preferredSource
        poll = Task {
            var requestAccess = askForAccess
            repeat {
                do {
                    let now = try await playback.read(preferred: source, requestAccess: requestAccess)
                    guard !Task.isCancelled else { return }
                    apply(now)
                    playerStatus = now.map { $0.isPlaying ? $0.source.title : "Paused in " + $0.source.title }
                        ?? "Open " + (source?.title ?? "Spotify or Apple Music") + " and play a song."
                } catch {
                    guard !Task.isCancelled else { return }
                    apply(nil)
                    playerStatus = error.localizedDescription
                }
                requestAccess = false
                try? await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled && active
        }
    }

    func apply(_ newTrack: StudioTrack?) {
        let previous = track
        let changed = track?.id != newTrack?.id
        let transportChanged = track?.isPlaying != newTrack?.isPlaying
        // Also catch seeks made directly in Spotify or Music between polls.
        if beatSync, let previous = track, let newTrack,
           abs(previous.position(at: newTrack.sampledAt) - newTrack.position) > 0.7 {
            meter.resetBeat()
        }
        track = newTrack
        if changed || transportChanged {
            meter.resetBeat()
            meter.followBeats(beatSync && active && !isPreview && newTrack?.isPlaying != false)
        }
        updateArtwork(from: previous, to: newTrack)
        guard changed else { return }
        lyricLoad?.cancel()
        lyricLoad = nil
        lyricOffset = 0
        lyrics = []
        lyricEffects = newTrack.flatMap { try? effectsStore.load(for: $0) }
        lyricsStatus = ""
        if newTrack != nil, showLyrics && wantsContent { retryLyrics() }
    }

    private func updateArtwork(from previous: StudioTrack?, to next: StudioTrack?) {
        let changedRecording = previous?.id != next?.id
        let changedInput = changedRecording || previous?.artworkData != next?.artworkData ||
            previous?.artworkURL != next?.artworkURL || previous?.album != next?.album ||
            previous?.duration != next?.duration || previous?.allowsCatalogArtwork != next?.allowsCatalogArtwork
        if changedInput {
            artworkLoad?.cancel()
            artworkLoad = nil
            needsCover = next != nil
            nextCoverAttempt = .distantPast
            coverRetryDelay = 2
            if changedRecording { artwork = nil }
            // A player can provide its own cover several snapshots after the title.
            if let data = next?.artworkData, StudioArtworkLookup.isDecodableArtwork(data), let image = NSImage(data: data) {
                artwork = image
                needsCover = false
            }
        }
        guard let next, needsCover, artworkLoad == nil, next.sampledAt >= nextCoverAttempt,
              next.artworkURL != nil || next.allowsCatalogArtwork else { return }
        artworkLoad = Task {
            do {
                let data = try await artworkLookup.cover(for: next)
                guard !Task.isCancelled, !isPreview, track?.id == next.id else { return }
                artworkLoad = nil
                if let data, let image = NSImage(data: data) {
                    artwork = image
                    needsCover = false
                } else {
                    // Avoid repeatedly searching for an unlisted release.
                    nextCoverAttempt = .now.addingTimeInterval(90)
                }
            } catch {
                guard !Task.isCancelled, !isPreview, track?.id == next.id else { return }
                artworkLoad = nil
                nextCoverAttempt = .now.addingTimeInterval(coverRetryDelay)
                coverRetryDelay = min(90, coverRetryDelay * 3)
            }
        }
    }

    func expandedArtwork(for id: String) async -> NSImage? {
        guard !isPreview, let track, track.id == id, track.source == .appleMusic,
              let local = track.artworkData,
              let data = try? await artworkLookup.image(artist: track.artist, album: track.album, original: local),
              !Task.isCancelled, self.track?.id == id else { return nil }
        return NSImage(data: data)
    }

    func saveLyricEffects(_ graph: StudioEffectsGraph?, trackID: String) throws {
        guard let track, track.id == trackID, !isPreview else {
            throw StudioEffectsGraph.GraphError.songChanged
        }
        try effectsStore.save(graph, for: track)
        lyricEffects = graph
    }

    func retryLyrics() {
        guard let track, !isPreview else { return }
        loadLyrics(for: track, file: nil)
    }

    func importLyrics() {
        guard let track, !isPreview else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose lyrics for " + track.title
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self, self.track?.id == track.id else { return }
            self.showLyrics = true
            self.loadLyrics(for: track, file: url)
        }
    }

    private func loadLyrics(for track: StudioTrack, file: URL?) {
        lyricLoad?.cancel()
        lyricsStatus = file == nil ? "Looking up timed lyrics…" : "Reading lyric file…"
        lyricLoad = Task {
            do {
                let lines: [StudioLine]
                if let file { lines = try await library.importFile(file, for: track) }
                else { lines = try await library.fetch(for: track) }
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                lyrics = lines
                if lines.first?.isEstimated == true { lyricsStatus = "Estimated timing" }
                else { lyricsStatus = lines.contains { !$0.words.isEmpty } ? "Word-synced lyrics" : "Line-synced lyrics" }
            } catch {
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                lyricsStatus = error.localizedDescription
            }
        }
    }

    private func updateMeter() {
        let previous = meterTask
        previous?.cancel()
        let enabled = active && (reactive || beatSync) && !isPreview
        meter.followBeats(enabled && beatSync && track?.isPlaying != false)
        meterStatus = nil
        meterTask = Task {
            // HAL may still be finishing a canceled start or stop on the meter actor.
            // Let it finish before applying the latest setting.
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                if enabled { try await meter.start() }
                else { await meter.stop() }
            } catch {
                guard !Task.isCancelled else { return }
                meterStatus = error.localizedDescription
            }
        }
    }

    func playPause() {
        if isPreview, let track {
            setPreviewTrack(position: position(at: .now), playing: !track.isPlaying)
        } else { send(.playPause) }
    }

    func previous() {
        if isPreview {
            if position(at: .now) < 3 { previewIndex = 1 - previewIndex }
            setPreviewTrack(position: 0, playing: track?.isPlaying ?? true)
        } else { send(.previous) }
    }

    func next() {
        if isPreview {
            previewIndex = 1 - previewIndex
            setPreviewTrack(position: 0, playing: track?.isPlaying ?? true)
        } else { send(.next) }
    }

    func seek(_ seconds: Double) {
        guard let track, seconds.isFinite else { return }
        let value = min(track.duration, max(0, seconds))
        if isPreview { setPreviewTrack(position: value, playing: track.isPlaying) }
        else { send(.seek(value)) }
    }

    private func send(_ command: StudioCommand) {
        guard let current = track else { return }
        // Stop the outstanding read before issuing a command so a delayed poll
        // cannot overwrite the new position or a newly selected source.
        poll?.cancel()
        let previous = commandTask
        let expectedGeneration = generation
        commandTask = Task {
            await previous?.value
            guard !Task.isCancelled, generation == expectedGeneration, !isPreview, active, track?.source == current.source else { return }
            do {
                try await playback.send(command, to: current.source)
                meter.resetBeat()
            } catch {
                guard !Task.isCancelled else { return }
                playerStatus = error.localizedDescription
            }
            guard !Task.isCancelled, generation == expectedGeneration, active, !isPreview else { return }
            // Restart the reader without cancelling queued transport operations.
            restartPolling()
        }
    }

    func startPreview() {
        generation += 1
        poll?.cancel()
        commandTask?.cancel()
        lyricLoad?.cancel()
        artworkLoad?.cancel()
        isPreview = true
        lyricEffects = nil
        previewIndex = 0
        artwork = nil
        playerStatus = "Silent preview"
        setPreviewTrack(position: 0, playing: true)
        updateMeter()
    }

    private func setPreviewTrack(position: Double, playing: Bool) {
        let first = previewIndex == 0
        let id = first ? "preview-night-ferry" : "preview-first-light"
        if track?.id != id { lyricOffset = 0 }
        let text = first ? [
            "Down on the East River", "The last boat slips away", "We leave the lights behind us",
            "One window still awake", "The water keeps the color", "Long after morning breaks"
        ] : [
            "Meet me at the station", "Just before the morning train", "Daylight on the platform",
            "Your reflection in the rain", "The doors slide slowly open", "And the city starts again"
        ]
        let starts = [0.0, 3.2, 6.3, 9.8, 13.3, 17.0]
        lyrics = zip(starts, text).map { StudioLine(start: $0, text: $1) }
        lyricsStatus = "Preview lyrics"
        track = StudioTrack(id: id, source: .appleMusic,
                                title: first ? "Night Ferry" : "First Light", artist: "Bliss Studio Sessions", album: "After Hours",
                                duration: 21, position: position, isPlaying: playing, sampledAt: .now,
                                artworkURL: nil, artworkData: nil)
    }
}
