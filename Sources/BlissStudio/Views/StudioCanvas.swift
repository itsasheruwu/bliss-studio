import SwiftUI

struct StudioCanvas: View {
    let session: StudioSession
    let onClose: () -> Void
    let onFullScreen: () -> Void
    var onCompanion: (() -> Void)? = nil
    var installKeyHandler: ((StudioPlayerKeyHandler?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var artworkPalette = StudioPalette.dusk
    @State private var lastInteraction = Date.now
    @State private var chromeQuiet = false
    @State private var overControls = false
    @State private var artworkExpanded = false
    @State private var effectsTrackID: String?
    @State private var requestedArtworkID: String?
    @State private var enhancedArtwork: NSImage?

    private var activeArtworkID: String? {
        guard artworkExpanded, !session.showLyrics, requestedArtworkID == session.track?.id else { return nil }
        return requestedArtworkID
    }

    private var palette: StudioPalette { artworkPalette.applying(session.paletteMode) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let compact = size.height < 535
            if let track = session.track, track.id == effectsTrackID, !session.isPreview {
                StudioEffectsEditor(session: session, track: track, palette: palette) {
                    effectsTrackID = nil
                    wakeControls()
                }
                .id(track.id)
            } else {
                playerStage(size: size, compact: compact)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in if case .active = phase { wakeControls() } }
        .task(id: lastInteraction) {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { chromeQuiet = true }
        }
        .task(id: activeArtworkID.flatMap { _ in session.artwork.map(ObjectIdentifier.init) }) {
            enhancedArtwork = nil
            guard let id = activeArtworkID, let image = await session.expandedArtwork(for: id),
                  !Task.isCancelled, activeArtworkID == id else { return }
            enhancedArtwork = image
        }
        .onChange(of: session.artwork, initial: true) { _, image in artworkPalette = .from(image) }
        .onChange(of: session.showLyrics) { _, showsLyrics in
            if showsLyrics { artworkExpanded = false }
        }
        .onChange(of: session.track?.id) { _, id in
            effectsTrackID = nil
            requestedArtworkID = nil
            enhancedArtwork = nil
            if id == nil { artworkExpanded = false }
        }
        .onAppear { installKeyHandler?(handlePlayerKey) }
        .onDisappear { installKeyHandler?(nil) }
        .onExitCommand { _ = handlePlayerKey(.escape) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bliss Studio")
    }

    private func playerStage(size: CGSize, compact: Bool) -> some View {
        ZStack {
            Color(red: 0.027, green: 0.025, blue: 0.036)
            if let track = session.track {
                Group {
                    if session.showLyrics {
                        StudioLyricsView(session: session, palette: palette, availableSize: size)
                            .padding(.top, 26).padding(.bottom, compact ? 100 : 130)
                    } else {
                        player(track: track, size: size)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else { waitingForPlayer }
            VStack(spacing: 0) {
                header
                    .opacity(controlOpacity)
                Spacer(minLength: 0)
                if let track = session.track {
                    footer(track: track, compact: compact)
                        .opacity(controlOpacity)
                }
            }
            .padding(.horizontal, max(18, min(32, size.width * 0.035)))
            .padding(.vertical, compact ? 15 : 22)
            if !session.desktopLightEnabled {
                StudioRim(session: session).ignoresSafeArea()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: session.showLyrics)
        .clipShape(Rectangle())
    }

    private var controlOpacity: Double {
        guard quietMode else { return 1 }
        return artworkExpanded ? 0.79 : 0.35
    }

    private var quietMode: Bool {
        chromeQuiet && !voiceOver && !overControls && session.track?.isPlaying == true
    }

    private func wakeControls() {
        if chromeQuiet || Date.now.timeIntervalSince(lastInteraction) > 0.40 {
            chromeQuiet = false
            lastInteraction = .now
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            // Leave space for a full-size, transparent macOS title bar's traffic lights.
            HStack(spacing: 7) {
                Image(systemName: "waveform").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.highlight)
                Text("Bliss Studio").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.77))
            }
            .padding(.leading, 62)
            Spacer(minLength: 12)
            Menu {
                if session.isPreview { Button("Connect to player", action: session.connect) }
                else { Button("Play silent preview", action: session.startPreview) }
                if let onCompanion { Button("Open artwork window", action: onCompanion) }
                if session.track != nil, session.showLyrics {
                    Menu("Lyric timing") {
                        if !session.lyrics.isEmpty { Text(session.lyricsStatus) }
                        Text(String(format: "%+.2f seconds", session.lyricOffset))
                        Button("Show lyrics 0.25s earlier") { session.lyricOffset += 0.25 }
                        Button("Show lyrics 0.25s later") { session.lyricOffset -= 0.25 }
                        Button("Reset timing") { session.lyricOffset = 0 }
                    }
                }
                if session.track != nil && !session.isPreview {
                    Divider()
                    Button("Import lyrics…", action: session.importLyrics)
                    if session.showLyrics { Button("Refresh lyrics", action: session.retryLyrics) }
                    Button("Edit lyric effects…") { effectsTrackID = session.track?.id }
                        .disabled(session.lyrics.isEmpty)
                    Divider()
                    Text(session.playerStatus)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 27, height: 26).contentShape(Rectangle())
            }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("More options").help("More options")
            SceneIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Toggle full screen",
                            diameter: 28, action: onFullScreen)
            SceneIconButton(symbol: "xmark", label: "Close Bliss Studio", diameter: 28, action: onClose)
        }
        .foregroundStyle(.white.opacity(0.77))
        .onHover { overControls = $0; if $0 { wakeControls() } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.48), value: controlOpacity)
    }

    private var waitingForPlayer: some View {
        VStack(spacing: 15) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .thin))
                .foregroundStyle(palette.highlight)
                .padding(.bottom, 3)
            Text("Waiting for music").font(.system(size: 26, weight: .semibold)).tracking(-0.7)
            Text(session.playerStatus)
                .font(.callout).foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center).frame(maxWidth: 345)
            HStack(spacing: 12) {
                Button("Connect to player", action: session.connect).buttonStyle(.borderedProminent)
                    .tint(palette.secondary.mix(with: .black, by: 0.36))
                Button("Try silent preview", action: session.startPreview).buttonStyle(.bordered)
            }
            .padding(.top, 5)
        }
        .foregroundStyle(.white)
        .padding(36)
    }

    private func player(track: StudioTrack, size: CGSize) -> some View {
        let compact = size.height < 535
        let side = max(82, min(340, min(size.width * 0.48, (size.height - (compact ? 220 : 275)) * 0.83)))
        let sleeve = Color.clear.frame(width: side, height: side)
            .anchorPreference(key: SleeveAnchor.self, value: .bounds) { $0 }
            .padding(.bottom, compact ? 2 : 4)
        return VStack(spacing: compact ? 9 : 13) {
            sleeve
            VStack(spacing: 3) {
                Text(track.title)
                    .font(.system(size: compact ? 22 : 29, weight: .semibold))
                    .tracking(-0.85).lineLimit(2).multilineTextAlignment(.center)
                Text(track.artist).font(.system(size: compact ? 12 : 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.69)).lineLimit(1)
            }
            .frame(maxWidth: min(500, size.width * 0.82))
            SceneScrubber(session: session, duration: track.duration, palette: palette)
                .frame(width: max(166, min(260, side * 1.02)))
            transport(track: track, compact: false)
                .padding(.top, compact ? 0 : 2)
        }
        .foregroundStyle(.white)
        .opacity(artworkExpanded ? 0 : 1)
        .accessibilityHidden(artworkExpanded)
        .allowsHitTesting(!artworkExpanded)
        .disabled(artworkExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 39).padding(.bottom, compact ? 54 : 75)
        .overlayPreferenceValue(SleeveAnchor.self) { anchor in
            GeometryReader { geo in
                if let anchor {
                    StudioArtworkStage(artwork: session.artwork, enhancedArtwork: activeArtworkID == nil ? nil : enhancedArtwork,
                                           isPreview: session.isPreview, palette: palette,
                                           resting: geo[anchor], size: geo.size, expanded: artworkExpanded, setExpanded: setExpanded)
                }
            }
        }
    }

    private func handlePlayerKey(_ key: StudioPlayerKey) -> Bool {
        if effectsTrackID != nil {
            if case .escape = key { effectsTrackID = nil; return true }
            return false
        }
        switch key {
        case .artwork:
            guard session.track != nil, !session.showLyrics else { return false }
            setExpanded(!artworkExpanded)
        case .escape:
            if artworkExpanded { setExpanded(false) } else { onClose() }
        }
        return true
    }

    private func setExpanded(_ expanded: Bool) {
        guard artworkExpanded != expanded else { return }
        requestedArtworkID = expanded ? session.track?.id : nil
        wakeControls()
        withAnimation(reduceMotion ? nil : .timingCurve(0.22, 0.82, 0.23, 1.0, duration: expanded ? 0.62 : 0.48)) {
            artworkExpanded = expanded
        }
    }

    private func footer(track: StudioTrack, compact: Bool) -> some View {
        VStack(spacing: 11) {
            if session.showLyrics || artworkExpanded {
                VStack(spacing: 3) {
                    Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.63)).lineLimit(1)
                    HStack(spacing: 14) {
                        transport(track: track, compact: true)
                        SceneScrubber(session: session, duration: track.duration, palette: palette)
                            .frame(width: 143)
                    }
                    .padding(.top, 3)
                }
                .frame(maxWidth: 380).padding(.bottom, compact ? 1 : 5)
            }
            ViewThatFits(in: .horizontal) {
                ZStack {
                    HStack {
                        Label(session.isPreview ? "Silent preview" : track.source.title,
                              systemImage: session.isPreview ? "speaker.slash.fill" : "music.note")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                        Spacer(minLength: 230)
                    }
                    modeSwitch
                }
                modeSwitch
            }
        }
        .foregroundStyle(.white)
        .onHover { overControls = $0; if $0 { wakeControls() } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.48), value: controlOpacity)
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton("Artwork", symbol: "rectangle.portrait", lyrics: false)
            modeButton("Lyrics", symbol: "quote.bubble", lyrics: true)
        }
        .padding(3)
        .background(.white.opacity(0.055), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.7) }
        .fixedSize()
    }

    private func modeButton(_ title: String, symbol: String, lyrics: Bool) -> some View {
        let selected = lyrics == session.showLyrics
        return Button {
            session.showLyrics = lyrics
            wakeControls()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color(white: 0.94) : Color(white: 0.63))
                .padding(.horizontal, 12).frame(height: 26)
                .background(selected ? .white.opacity(0.135) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func transport(track: StudioTrack, compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 12) {
            SceneIconButton(symbol: "backward.end.fill", label: "Previous track", diameter: compact ? 23 : 31,
                            action: session.previous)
            SceneIconButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", label: track.isPlaying ? "Pause" : "Play",
                            diameter: compact ? 29 : 43, primary: true, action: session.playPause)
                .keyboardShortcut(.space, modifiers: [])
            SceneIconButton(symbol: "forward.end.fill", label: "Next track", diameter: compact ? 23 : 31,
                            action: session.next)
        }
    }
}

private struct SleeveAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct SceneIconButton: View {
    let symbol: String
    let label: String
    var diameter: CGFloat
    var primary = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * (primary ? 0.35 : 0.41), weight: .semibold))
                .foregroundStyle(primary ? Color(white: 0.12) : Color(white: hovered ? 1 : 0.78))
                .frame(width: diameter, height: diameter)
                .background(primary ? Color(white: hovered ? 1 : 0.93) : .white.opacity(hovered ? 0.16 : 0.045), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(primary ? 0.18 : 0.09), lineWidth: 0.65) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(label).accessibilityLabel(label)
    }
}

private struct SceneScrubber: View {
    let session: StudioSession
    let duration: Double
    let palette: StudioPalette
    @State private var scrub: Double?
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: session.track?.isPlaying == true ? 0.25 : 1)) { timeline in
            let current = scrub ?? session.position(at: timeline.date)
            let fraction = duration > 0 ? min(1, max(0, current / duration)) : 0
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.19)).frame(height: 2.5)
                        Capsule().fill(palette.highlight).frame(width: geo.size.width * fraction, height: 2.5)
                        if hovered || scrub != nil {
                            Circle().fill(.white).frame(width: 7, height: 7)
                                .offset(x: max(0, (geo.size.width - 7) * fraction))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in scrub = min(1, max(0, value.location.x / max(1, geo.size.width))) * duration }
                        .onEnded { value in
                            session.seek(min(1, max(0, value.location.x / max(1, geo.size.width))) * duration)
                            scrub = nil
                        })
                }
                .frame(height: 13)
                HStack {
                    Text(Self.timestamp(current))
                    Spacer()
                    Text(Self.timestamp(duration))
                }
                .monospacedDigit().font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.57))
            }
            .onHover { hovered = $0 }
            .accessibilityElement(children: .ignore).accessibilityLabel("Playback position")
            .accessibilityValue("\(Self.timestamp(current)) of \(Self.timestamp(duration))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: session.seek(min(duration, current + 5))
                case .decrement: session.seek(max(0, current - 5))
                @unknown default: break
                }
            }
            .focusable(duration > 0)
            .onMoveCommand { direction in
                if direction == .right { session.seek(min(duration, current + 5)) }
                if direction == .left { session.seek(max(0, current - 5)) }
            }
        }
        .disabled(duration <= 0)
    }

    private static func timestamp(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 86_400_000 else { return "–:––" }
        let seconds = Int(value)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
